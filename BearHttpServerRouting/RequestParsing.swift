//
//  RequestParsing.swift
//  BearHttpServerRouting
//

import Foundation
import BearHttpServer

// MARK: - 百分号解码

/// 百分号解码，`+` 按表单语义转空格。
/// 畸形序列（ `%` 后不足两位十六进制）原样保留，不崩溃。
@inline(__always)
func percentDecode(_ value: String, plusAsSpace: Bool) -> String {
    let bytes = Array(value.utf8)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count)

    func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48          // 0-9
        case 65...70: return c - 65 + 10     // A-F
        case 97...102: return c - 97 + 10    // a-f
        default: return nil
        }
    }

    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if plusAsSpace && b == 43 {          // '+'
            out.append(32)
            i += 1
        } else if b == 37, i + 2 < bytes.count, // '%'
                  let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
            out.append(hi << 4 | lo)
            i += 3
        } else {
            out.append(b)
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - HTTPRequest 解析辅助

extension HTTPRequest {
    /// 请求路径（去掉 `?` 及其后的 query），已做百分号解码。
    /// 例：`/users/a%20b?x=1` → `/users/a b`
    public var path: String {
        let raw = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return percentDecode(String(raw.first ?? ""), plusAsSpace: false)
    }

    /// query 字符串（不含 `?`），未解码。
    public var query: String {
        guard let q = target.firstIndex(of: "?") else { return "" }
        return String(target[target.index(after: q)...])
    }

    /// 解析后的 query 项，顺序与原始字符串一致。
    /// 无 `=` 的参数值为空串；`+` 转空格；百分号解码。
    public var queryItems: [URLQueryItem] {
        let q = query
        guard !q.isEmpty else { return [] }
        return q.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(parts.first ?? "")
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            return URLQueryItem(
                name: percentDecode(rawName, plusAsSpace: true),
                value: percentDecode(rawValue, plusAsSpace: true)
            )
        }
    }

    /// 取指定 query 参数值（解码后），多个同名取第一个。
    public func query(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    /// 解析 `Cookie` 头：按 `;` 拆分、按 `=` 拆分，值去首尾引号。
    /// 重复键后者覆盖；大小写敏感（Cookie 名按 RFC 区分大小写）。
    public var cookies: [String: String] {
        guard let raw = headers["cookie"], !raw.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<eq])
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !name.isEmpty { result[name] = value }
        }
        return result
    }

    /// 取指定 Cookie 值，不存在返回 nil。
    public func cookie(_ name: String) -> String? {
        cookies[name]
    }
}
