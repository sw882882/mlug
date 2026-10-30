package dev.mlug

/** Wire protocol, mirrored from mac/Sources/MlugCore/Protocol.swift. */
object Wire {
    const val PORT = 38281
    const val VERSION = 1

    // Mac -> tablet
    const val CONFIG = 1
    const val FRAME = 2

    // Tablet -> Mac
    const val HELLO = 1
    const val POINTER = 2
    const val SCROLL = 3
    const val KEYFRAME = 4

    const val MOVE = 0
    const val DOWN = 1
    const val UP = 2
    const val LEFT = 0
    const val RIGHT = 1
}
