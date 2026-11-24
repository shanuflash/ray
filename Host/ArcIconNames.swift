// Adapted from Open Arc's app/Sources/OpenArcImport/ArcIconNames.swift (https://github.com/St0neWan9/open-arc-browser, BSD-3-Clause):
//
// Copyright 2026 The Open Arc Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import AppKit

/// Arc's named Space icons (`customInfo.iconType.icon`: "bulb", "flash", "colorPallete"…) and the SF Symbol each
/// becomes, so an imported Space keeps its icon. Open Arc's table (its names inferred, its symbols its own picks).
enum ArcIconNames {
    static let symbols: [String: String] = [
        "star": "star.fill",
        "heart": "heart.fill",
        "flag": "flag.fill",
        "flash": "bolt.fill",
        "triangle": "triangle.fill",
        "medical": "cross.case.fill",
        "notifications": "bell.fill",
        "bulb": "lightbulb.fill",
        "shapes": "square.on.circle.fill",
        "grid": "square.grid.2x2.fill",
        "apps": "circle.grid.3x3.fill",
        "layers": "square.3.layers.3d",
        "albums": "rectangle.stack.fill",
        "copy": "doc.on.doc.fill",
        "fileTrayFull": "tray.full.fill",
        "calendar": "calendar",
        "mail": "envelope.fill",
        "checkbox": "checkmark.square.fill",
        "book": "book.fill",
        "people": "person.2.fill",
        "terminal": "apple.terminal.fill",
        "construction": "hammer.fill",
        "square": "square.fill",
        "ellipse": "circle.fill",
        "moon": "moon.fill",
        "sunny": "sun.max.fill",
        "planet": "globe.americas.fill",
        "leaf": "leaf.fill",
        "cloud": "cloud.fill",
        "gift": "gift.fill",
        "restaurant": "fork.knife",
        "barbell": "dumbbell.fill",
        "airplane": "airplane",
        "musicalNote": "music.note",
        "colorPallete": "paintpalette.fill",
        "bandage": "bandage.fill",
        "code": "chevron.left.forwardslash.chevron.right",
        "baseball": "baseball.fill",
        "cloudOutline": "cloud",
        "bonfire": "flame.fill",
        "pizza": "takeoutbag.and.cup.and.straw.fill",
        "skull": "theatermasks.fill",
        "receipt": "receipt.fill",
        "thumbsUp": "hand.thumbsup.fill",
        "train": "tram.fill",
        "search": "magnifyingglass",
        "chatBubbleEllipses": "ellipsis.bubble.fill",
    ]
}
