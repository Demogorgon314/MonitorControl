//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os.log

enum RemoteControlServerStatus: Equatable {
  case stopped
  case running(port: UInt16)
  case failed(message: String)
}

final class RemoteControlServer {
  private let requestExecutionQueue = DispatchQueue(label: "RemoteControlServer.request")
  private var router: RemoteAPIRouter?
  private var eventLoopGroup: MultiThreadedEventLoopGroup?
  private var serverChannel: Channel?

  var statusChangeHandler: ((RemoteControlServerStatus) -> Void)?

  private(set) var status: RemoteControlServerStatus = .stopped {
    didSet {
      self.statusChangeHandler?(self.status)
    }
  }

  func start(port: UInt16, tokenProvider: @escaping () -> String) throws {
    self.stop()

    let router = RemoteAPIRouter(displayController: .shared, tokenProvider: tokenProvider)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, System.coreCount))

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
      .childChannelInitializer { [weak self] channel in
        guard let self else {
          return channel.eventLoop.makeSucceededFuture(())
        }
        return channel.pipeline.addHandler(IdleStateHandler(readTimeout: .seconds(5))).flatMap {
          channel.pipeline.addHandler(HTTPResponseEncoder())
        }.flatMap {
          channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)))
        }.flatMap {
          channel.pipeline.addHandler(
            RemoteNIORequestHandler(
              requestExecutionQueue: self.requestExecutionQueue,
              routeRequest: { request in router.route(request) }
            )
          )
        }
      }

    do {
      let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
      self.router = router
      self.eventLoopGroup = group
      self.serverChannel = channel
      self.status = .running(port: port)
      os_log("Remote HTTP server is listening on port %{public}@", type: .info, String(port))
    } catch {
      try? group.syncShutdownGracefully()
      self.status = .failed(message: "unable to start server: \(error.localizedDescription)")
      throw NSError(
        domain: "RemoteControlServer",
        code: Int((error as NSError).code),
        userInfo: [NSLocalizedDescriptionKey: "unable to start remote HTTP server"]
      )
    }
  }

  func stop() {
    if let channel = self.serverChannel {
      try? channel.close(mode: .all).wait()
      self.serverChannel = nil
    }

    if let group = self.eventLoopGroup {
      try? group.syncShutdownGracefully()
      self.eventLoopGroup = nil
    }

    self.router = nil
    self.status = .stopped
  }
}
