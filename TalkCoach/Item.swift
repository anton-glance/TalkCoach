//
//  Item.swift
//  TalkCoach
//
//  Created by Anton Glance on 5/1/26.
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
