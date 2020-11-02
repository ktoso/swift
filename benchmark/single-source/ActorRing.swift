//===--- StringTests.swift ------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TestsUtils

public let StringTests = [
  BenchmarkInfo(
    name: "RingBenchmarks.bench_ring_m100_000_n10_000",
    runFunction: bench_ring_m100_000_n10_000,
    tags: [.actor]),
]

// === -----------------------------------------------------------------------------------------------------------------
private let q = LinkedBlockingQueue<Int>()

private let spawnStart = Atomic<UInt64>(value: 0)
private let spawnStop = Atomic<UInt64>(value: 0)

private let ringStart = Atomic<UInt64>(value: 0)
private let ringStop = Atomic<UInt64>(value: 0)

// === -----------------------------------------------------------------------------------------------------------------

private struct Token: ActorMessage {
  let payload: Int

  init(_ payload: Int) {
    self.payload = payload
  }
}

private let mutex = _Mutex()

actor class TokenLoop {

  let id: Int
  let next: LoopMember
  let msg: Token

  init(id: Int, next: LoopMember, msg: Token) {
    self.id = id
    self.next = next
    self.msg = msg

    if id == 1 {
      // I am the leader and shall create the ring
      self.spawnActorRing()
    }
  }

  private func spawnActorRing(actors: Int) {
    // TIME: spawning
    spawnStart.store(SwiftBenchmarkTools.Timer().getTimeAsInt())

    var loopRef: TokenLoopActor = self
    for i in (1...actors).reversed() {
      loopRef = TokenLoopActor(id: i, next: loopRef, msg: Token(messages))
    }

    // END TIME: spawning
    spawnStop.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
  }

  func pass(_ token: Token) async {
    switch token.payload {
    case 1:
      ringStop.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
      q.enqueue(0) // done
      // stop. this actor could "stop" now

    default:
      next.pass(Token(msg.payload - 1))
    }
  }
}

private var loopEntryPoint: TokenLoopActor!

private func initLoop(m messages: Int, n actors: Int) {
  // TIME spawning
  spawnStart.store(SwiftBenchmarkTools.Timer().getTimeAsInt())

  loopEntryPoint = TokenLoopActor(id: 1, next: next, msg:
}

//  private func initLoop(m messages: Int, n actors: Int) {
//    loopEntryPoint = try! system.spawn(
//      "a0",
//      .setup { context in
//        // TIME spawning
//        // pprint("START SPAWN... \(SwiftBenchmarkTools.Timer().getTimeAsInt())")
//        spawnStart.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
//
//        var loopRef = context.myself
//        for i in (1 ... actors).reversed() {
//          loopRef = try context.spawn("a\(actors - i)", loopMember(id: i, next: loopRef, msg: Token(messages)))
//          // context.log.info("SPAWNed \(loopRef.path.name)...")
//        }
//        // pprint("DONE SPAWN... \(SwiftBenchmarkTools.Timer().getTime())")
//        spawnStop.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
//
//        return .receiveMessage { m in
//          // pprint("START RING SEND... \(SwiftBenchmarkTools.Timer().getTime())")
//
//          // context.log.info("Send \(m) \(context.myself.path.name) >>> \(loopRef.path.name)")
//          loopRef.tell(m)
//
//          // END TIME spawning
//          return loopMember(id: 1, next: loopRef, msg: m)
//        }
//      }
//    )
//  }

}

// === -----------------------------------------------------------------------------------------------------------------
func bench_ring_m100_000_n10_000(n: Int) {
  ringStart.store(SwiftBenchmarkTools.Timer().getTimeAsInt())
  loopEntryPoint.tell(Token(100_000))

  _ = q.poll(.seconds(20))
  pprint("    Spawning           : \((spawnStop.load() - spawnStart.load()).milliseconds) ms")
  pprint("    Sending around Ring: \((ringStop.load() - ringStart.load()).milliseconds) ms")
}
