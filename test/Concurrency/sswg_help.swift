// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency -disable-availability-checking
// REQUIRES: concurrency
// REQUIRES: executable_test

public typealias _MiddlewareSendable = Sendable
public protocol _MiddlewareSendableProtocol: Sendable {}

public protocol HandlerProtocol<InputType, OutputType, ContextType>: _MiddlewareSendable {
  associatedtype InputType
  associatedtype OutputType
  associatedtype ContextType

  func handle(input: InputType, context: ContextType) async throws -> OutputType
}


public struct MiddlewareContext { }

public protocol MiddlewareProtocol: _MiddlewareSendable {
  associatedtype InputType
  associatedtype OutputType

  @Sendable
  func handle<HandlerType: MiddlewareHandlerProtocol>(
          input: InputType,
          context: MiddlewareContext,
          next: HandlerType) async throws -> OutputType
          where HandlerType.InputType == InputType, HandlerType.OutputType == OutputType
}

public protocol MiddlewareHandlerProtocol<InputType, OutputType, ContextType>: HandlerProtocol where ContextType == MiddlewareContext {
}

public protocol HttpServerRequestProtocol {
  // something will probably go here
}

public protocol HttpServerResponseBuilderProtocol {
  associatedtype HTTPResponseType: HttpServerResponseProtocol

  init()

}

public protocol HTTPBodyProtocol {}

public enum HTTPResponseStatus {}

public enum HTTPVersion {}

public protocol HttpServerResponseProtocol {
  associatedtype HeadersType: HttpHeadersProtocol
  associatedtype BodyType: HTTPBodyProtocol
  associatedtype AdditionalResponsePropertiesType

  init(headers: HeadersType, status: HTTPResponseStatus,
       httpVersion: HTTPVersion, body: BodyType?,
       additionalResponseProperties: AdditionalResponsePropertiesType?) throws
}

public protocol HttpHeadersProtocol: Equatable {
}

public protocol ServerRouterOutputProtocol<InputType, OutputType> {
  associatedtype InputType: HttpServerRequestProtocol
  associatedtype OutputType: HttpServerResponseBuilderProtocol
  associatedtype HandlerType: MiddlewareHandlerProtocol<InputType, OutputType, MiddlewareContext>

  var httpRequest: HandlerType.InputType { get }
  var handler: HandlerType { get }
}

public struct ServerRouterOutput<HandlerType: MiddlewareHandlerProtocol>: ServerRouterOutputProtocol
        where HandlerType.InputType: HttpServerRequestProtocol,
        HandlerType.OutputType: HttpServerResponseBuilderProtocol {
  public typealias InputType = HandlerType.InputType
  public typealias OutputType = HandlerType.OutputType

  public let httpRequest: HandlerType.InputType
  public let handler: HandlerType

  public init(httpRequest: HandlerType.InputType,
              handler: HandlerType) {
    self.httpRequest = httpRequest
    self.handler = handler
  }
}

public protocol ServerRouterProtocol: Sendable {
  associatedtype InputHTTPRequestType: HttpServerRequestProtocol
  associatedtype OutputHTTPRequestType: HttpServerRequestProtocol
  associatedtype HTTPResponseType: HttpServerResponseProtocol

  @Sendable
  func select(
          httpRequest: InputHTTPRequestType,
          context: MiddlewareContext) async throws -> any ServerRouterOutputProtocol<OutputHTTPRequestType, HTTPResponseType>
}


public struct BuildServerResponsePhaseHandler<ServerRouterType: ServerRouterProtocol>: MiddlewareHandlerProtocol {

  public typealias InputType = ServerRouterType.InputHTTPRequestType

  public typealias OutputType = ServerRouterType.HTTPResponseType

  let router: ServerRouterType

  public init(router: ServerRouterType) {
    self.router = router
  }

  public func handle(input: InputType, context: MiddlewareContext) async throws -> OutputType {
    let routerOutput: any ServerRouterOutputProtocol<ServerRouterType.OutputHTTPRequestType, ServerRouterType.HTTPResponseType>
            = try await self.router.select(httpRequest: input, context: context)
    let handler: any MiddlewareHandlerProtocol<ServerRouterType.OutputHTTPRequestType, ServerRouterType.HTTPResponseType, MiddlewareContext>
            = routerOutput.handler // Type of expression is ambiguous without more context
    // Inferred result type 'any MiddlewareHandlerProtocol' requires explicit coercion due to loss of generic requirements
    // as! any MiddlewareHandlerProtocol<ServerRouterType.OutputHTTPRequestType, ServerRouterType.HTTPResponseType, MiddlewareContext> // FIXME: how do we make this as! not necessary?

    return try await handler.handle(input: routerOutput.httpRequest, context: context)
  }
}
