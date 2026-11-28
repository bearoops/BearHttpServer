//
//  ServerView.swift
//  BearHttpServerDemo
//

import Foundation
import Combine
import SwiftUI
import BearHttpServer

struct ServerRequestRecord: Identifiable, Sendable {
    let id = UUID()
    let time = Date()
    let method: String
    let target: String
}

@MainActor
final class ServerViewModel: ObservableObject {
    @Published var host = "0.0.0.0"
    @Published var portText = "8080"
    @Published private(set) var isRunning = false
    @Published private(set) var boundPort: UInt16?
    @Published private(set) var statusMessage = "尚未启动"
    @Published private(set) var requests: [ServerRequestRecord] = []

    private var server: HTTPServer?

    var displayAddress: String? {
        guard let boundPort else { return nil }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayHost = host == "0.0.0.0" ? "<设备局域网 IP>" : host
        return "http://\(displayHost):\(boundPort)/"
    }

    func toggle() async {
        if isRunning {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            statusMessage = "请填写绑定地址"
            return
        }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            statusMessage = "端口需为 1...65535"
            return
        }

        let configuration = HTTPServerConfiguration(host: address, port: port)
        let server = HTTPServer(configuration: configuration) { [weak self] request in
            await self?.record(request)
            if request.target == "/health" {
                return .text("ok")
            }
            let body = String(data: request.body, encoding: .utf8) ?? ""
            return .text("""
            Hello from BearHttpServer
            \(request.method.rawValue) \(request.target)
            body: \(body)
            """)
        }

        do {
            let boundPort = try await server.start()
            self.server = server
            self.boundPort = boundPort
            isRunning = true
            statusMessage = "服务已启动"
        } catch {
            self.server = nil
            self.boundPort = nil
            isRunning = false
            statusMessage = "启动失败：\(error.localizedDescription)"
        }
    }

    func stop() async {
        let current = server
        server = nil
        await current?.stop()
        isRunning = false
        boundPort = nil
        statusMessage = "服务已停止"
    }

    private func record(_ request: HTTPRequest) {
        let record = ServerRequestRecord(
            method: request.method.rawValue,
            target: request.target
        )
        requests.insert(record, at: 0)
        if requests.count > 50 {
            requests.removeLast()
        }
    }
}

struct ServerView: View {
    @StateObject private var model = ServerViewModel()

    var body: some View {
        Form {
            Section("监听设置") {
                Picker("绑定地址", selection: $model.host) {
                    Text("本机 · 127.0.0.1").tag("127.0.0.1")
                    Text("局域网 · 0.0.0.0").tag("0.0.0.0")
                }
                TextField("端口", text: $model.portText)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                Button {
                    Task { await model.toggle() }
                } label: {
                    Label(
                        model.isRunning ? "停止服务" : "启动服务",
                        systemImage: model.isRunning ? "stop.circle.fill" : "play.circle.fill"
                    )
                }
            }
            .disabled(model.isRunning)

            Section("状态") {
                Label(
                    model.isRunning ? "运行中" : "未运行",
                    systemImage: model.isRunning ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(model.isRunning ? .green : .secondary)
                if let address = model.displayAddress {
                    Text(address)
                        .textSelection(.enabled)
                }
                Text(model.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("最近请求") {
                if model.requests.isEmpty {
                    Text("暂无请求")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.requests) { record in
                        HStack {
                            Text(record.method)
                                .font(.caption.weight(.semibold))
                            Text(record.target)
                                .lineLimit(1)
                            Spacer()
                            Text(record.time, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("服务页面")
    }
}
