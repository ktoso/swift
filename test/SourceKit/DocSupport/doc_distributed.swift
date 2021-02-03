// RUN: %empty-directory(%t.mod)
// RUN: %swift -enable-experimental-concurrency -emit-module -o %t.mod/async.swiftmodule %s -parse-as-library -emit-module-doc-path %t.mod/async.swiftdoc
// RUN: %sourcekitd-test -req=doc-info -module async -- -I %t.mod | %FileCheck %s

// REQUIRES: concurrency

public actor class DistProto {
  distributed func protoDistFunc() 
  // CHECK: key.usr: "s:5async10DistProtoP05protoB4FuncyyYF"
  // CHECK-NOT: }
  // CHECK: key.is_async: 1
  // CHECK: }
  func protoNonDistFunc()
  // CHECK: key.usr: "s:5async10DistProtoP08protoNonB4FuncyyF"
  // CHECK-NOT: key.is_async: 1
  // CHECK: }
}

public struct DistStruct: DistProto {
  distributed public func structDistFunc() { }
// CHECK: key.usr: "s:5async11DistStructV06structB4FuncyyYF"
// CHECK-NOT: }
// CHECK: key.is_async: 1
// CHECK: }
public func structNonDistFunc() { }
// CHECK: key.usr: "s:5async11DistStructV09structNonB4FuncyyF"
// CHECK-NOT: key.is_async: 1
// CHECK: }

public distributed func protoDistFunc() { }
// CHECK: key.usr: "s:5async11DistStructV05protoB4FuncyyYF"
// CHECK-NOT: }
// CHECK: key.conforms
// CHECK: {
// CHECK: key.usr: "s:5async10DistProtoP05protoB4FuncyyYF"
// CHECK-NOT: }
// CHECK: key.is_async: 1
// CHECK: }
// CHECK: key.is_async: 1
// CHECK: }
public func protoNonDistFunc() { }
// CHECK: key.usr: "s:5async11DistStructV08protoNonB4FuncyyF"
// CHECK-NOT: key.is_async: 1
// CHECK: }
}

public distributed func topLevelDistFunc() async { }
// CHECK: key.usr: "s:5async17topLevelDistFuncyyYF"
// CHECK-NOT: }
// CHECK: key.is_async: 1
// CHECK: }
public func topLevelNonDistFunc() { }
// CHECK: key.usr: "s:5async20topLevelNonDistFuncyyF"
// CHECK-NOT: key.is_async: 1
// CHECK: }

