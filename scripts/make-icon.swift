// Generate the CCBar app icon by rendering a SF Symbol onto a rounded-square
// blue gradient, then writing a 1024x1024 PNG. Run by scripts/build-app.sh.
//
// Usage:  swift scripts/make-icon.swift <output-png-path>

import SwiftUI
import AppKit

@MainActor
func render(to outputPath: String) throws {
    let size: CGFloat = 1024

    // The icon: rounded blue gradient + white "speech bubbles" SF Symbol.
    // macOS app icon mask isn't applied automatically, so we draw the
    // rounded corners ourselves at the standard macOS app icon radius
    // (~22% of side).
    let view = ZStack {
        RoundedRectangle(cornerRadius: 226, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.38, green: 0.55, blue: 0.98),
                        Color(red: 0.20, green: 0.34, blue: 0.84),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

        Image(systemName: "bubble.left.and.bubble.right.fill")
            .resizable()
            .scaledToFit()
            .padding(220)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 12, y: 8)
    }
    .frame(width: size, height: size)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else {
        FileHandle.standardError.write(Data("ImageRenderer.cgImage was nil\n".utf8))
        exit(2)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = NSSize(width: size, height: size)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("PNG representation failed\n".utf8))
        exit(3)
    }
    try png.write(to: URL(fileURLWithPath: outputPath))
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output-png>\n".utf8))
    exit(1)
}

do {
    try await MainActor.run {
        try render(to: args[1])
    }
    print("✓ wrote \(args[1])")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(4)
}
