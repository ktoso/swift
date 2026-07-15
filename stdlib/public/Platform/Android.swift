//===----------------------------------------------------------------------===//
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

@_exported import SwiftAndroid // Clang module
import SwiftOverlayShims

nonisolated(unsafe) public var stdin: UnsafeMutablePointer<FILE>! {
  _swift_stdlib_stdin().assumingMemoryBound(to: FILE.self)
}
nonisolated(unsafe) public var stdout: UnsafeMutablePointer<FILE>! {
  _swift_stdlib_stdout().assumingMemoryBound(to: FILE.self)
}
nonisolated(unsafe) public var stderr: UnsafeMutablePointer<FILE>! {
  _swift_stdlib_stderr().assumingMemoryBound(to: FILE.self)
}
