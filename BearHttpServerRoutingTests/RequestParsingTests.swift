//
//  RequestParsingTests.swift
//  BearHttpServerRoutingTests
//

import Testing
import Foundation
import BearHttpServer
@testable import BearHttpServerRouting

private func request(_ target: String, headers: HTTPHeaders = HTTPHeaders()) -> HTTPRequest {
    HTTPRequest(method: .get, target: target, headers: headers)
}

@Suite struct RequestParsingTests {
    @Test func pathStripsQuery() {
        #expect(request("/users/a%20b?x=1").path == "/users/a b")
        #expect(request("/plain").path == "/plain")
        #expect(request("/trailing?").path == "/trailing")
    }

    @Test func pathKeepsPlusLiteral() {
        // path 不做 + → 空格（那是表单 query 的语义）
        #expect(request("/a+b").path == "/a+b")
    }

    @Test func malformedPercentIsPreserved() {
        #expect(request("/%ZZ?x=%ZZ").path == "/%ZZ")
        #expect(request("/x?bad=%A").query("bad") == "%A")
        #expect(request("/x?bad=%").query("bad") == "%")
    }

    @Test func queryParsingBasics() {
        let r = request("/x?name=Alice&age=20&empty=&flag")
        #expect(r.query("name") == "Alice")
        #expect(r.query("age") == "20")
        #expect(r.query("empty") == "")
        #expect(r.query("flag") == "")
        #expect(r.query("missing") == nil)
        #expect(r.queryItems.count == 4)
    }

    @Test func queryPlusAndPercentDecoding() {
        let r = request("/x?q=hello+world&n=a%20b&cn=%E4%B8%AD")
        #expect(r.query("q") == "hello world")
        #expect(r.query("n") == "a b")
        #expect(r.query("cn") == "中")
    }

    @Test func queryDuplicateTakesFirst() {
        let r = request("/x?a=1&a=2")
        #expect(r.query("a") == "1")
        #expect(r.queryItems.count == 2)
    }

    @Test func emptyQuery() {
        #expect(request("/x").queryItems.isEmpty)
        #expect(request("/x?").queryItems.isEmpty)
    }

    @Test func cookiesParsing() {
        let r = request("/", headers: ["Cookie": "session=abc123; theme=dark; empty="])
        #expect(r.cookie("session") == "abc123")
        #expect(r.cookie("theme") == "dark")
        #expect(r.cookie("empty") == "")
        #expect(r.cookie("missing") == nil)
        #expect(r.cookies.count == 3)
    }

    @Test func cookieHeaderNameIsCaseInsensitive() {
        let r = request("/", headers: ["cookie": "a=1"])
        #expect(r.cookie("a") == "1")
    }

    @Test func cookieDuplicateKeepsLast() {
        let r = request("/", headers: ["Cookie": "a=1; a=2"])
        #expect(r.cookie("a") == "2")
    }

    @Test func cookieTrimsQuotesAndSpaces() {
        let r = request("/", headers: ["Cookie": " token = \" quoted \" ; bare=x "])
        #expect(r.cookie("token") == " quoted ")
        #expect(r.cookie("bare") == "x")
    }

    @Test func noCookieHeader() {
        #expect(request("/").cookies.isEmpty)
        #expect(request("/").cookie("x") == nil)
    }

    @Test func percentDecodeIsAvailableInternally() {
        #expect(percentDecode("a%2Bb", plusAsSpace: false) == "a+b")
        #expect(percentDecode("a+b", plusAsSpace: true) == "a b")
        #expect(percentDecode("%C3%A9", plusAsSpace: false) == "é")
    }
}
