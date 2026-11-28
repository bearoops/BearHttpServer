//
//  ClientView.swift
//  BearHttpServerDemo
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ClientViewModel: ObservableObject {
    @Published var host = "127.0.0.1"
    @Published var port = "8080"
    @Published var method = "GET"
    @Published var path = "/health"
    @Published var bodyText = ""
    @Published private(set) var responseText = "尚未发送请求"
    @Published private(set) var isSending = false

    func send() async {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let portValue = UInt16(trimmedPort) else {
            responseText = "请填写有效的主机和端口"
            return
        }

        let normalizedPath = trimmedPath.hasPrefix("/") ? trimmedPath : "/" + trimmedPath
        guard let url = URL(string: "http://\(trimmedHost):\(portValue)\(normalizedPath)") else {
            responseText = "URL 无效"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if !bodyText.isEmpty {
            request.httpBody = bodyText.data(using: .utf8)
        }

        isSending = true
        defer { isSending = false }

        do {
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? data.description
            responseText = "状态：\(status)\n\n\(body)"
        } catch {
            responseText = "请求失败：\(error.localizedDescription)"
        }
    }
}

struct ClientView: View {
    @StateObject private var model = ClientViewModel()

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        Form {
            Section("请求目标") {
                Picker("方法", selection: $model.method) {
                    ForEach(methods, id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                TextField("主机", text: $model.host)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                TextField("端口", text: $model.port)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                TextField("路径", text: $model.path)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
            }

            Section("请求体") {
                TextEditor(text: $model.bodyText)
                    .frame(minHeight: 80)
            }

            Section {
                Button {
                    Task { await model.send() }
                } label: {
                    Label("发送请求", systemImage: "paperplane.fill")
                }
                .disabled(model.isSending)
            }

            Section("响应") {
                ScrollView {
                    Text(model.responseText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120)
            }
        }
        .navigationTitle("客户端页面")
    }
}
