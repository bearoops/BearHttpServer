//
//  Item.swift
//  BearHttpServerDemo
//
//  Created by 李招雄 on 2026/11/28.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date

    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
