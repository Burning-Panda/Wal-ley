//
//  Item.swift
//  wal-ley
//
//  Created by André Tørlen Lønvik on 12/10/2026.
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
