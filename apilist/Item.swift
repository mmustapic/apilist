//
//  Item.swift
//  apilist
//
//  Created by Marco Mustapic on 12/05/2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var uid: String
    var title: String
    var text: String
    var timestamp: Date
    var completed: Bool

    init(title: String, text: String) {
        self.uid = UUID().uuidString
        self.title = title
        self.text = text
        self.timestamp = Date.now
        self.completed = false
    }
}
