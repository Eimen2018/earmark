// Renders the Earmark app icon: a caption page with a dog-eared corner (an "earmark")
// and one line held in pink highlighter, on an ink-blue macOS squircle.
// Usage: swift Scripts/render-icon.swift <out.png>
import AppKit
import SwiftUI

struct Icon: View {
    let ink1 = Color(red: 0.11, green: 0.16, blue: 0.29)
    let ink2 = Color(red: 0.20, green: 0.30, blue: 0.52)
    let paper = Color(red: 1.0, green: 0.97, blue: 0.85)
    let fold = Color(red: 0.93, green: 0.85, blue: 0.62)
    let rule = Color(red: 0.11, green: 0.16, blue: 0.29).opacity(0.22)
    let marker = Color(red: 1.0, green: 0.55, blue: 0.75)
    let text = Color(red: 0.11, green: 0.16, blue: 0.29)

    var body: some View {
        ZStack {
            // macOS icon grid: 824pt body inside a 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [ink2, ink1], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
            page
                .rotationEffect(.degrees(-7))
                .offset(x: -6, y: 10)
        }
        .frame(width: 1024, height: 1024)
    }

    var page: some View {
        let w: CGFloat = 500, h: CGFloat = 600, ear: CGFloat = 130
        return ZStack(alignment: .topLeading) {
            PageShape(ear: ear)
                .fill(paper)
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 18)
            // caption lines
            VStack(alignment: .leading, spacing: 46) {
                bar(width: 250, color: rule)
                bar(width: 360, color: rule)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 12).fill(marker)
                        .frame(width: 400, height: 74)
                        .offset(x: -18)
                    bar(width: 300, color: text, height: 30)
                        .offset(x: 6)
                }
                bar(width: 330, color: rule)
                bar(width: 220, color: rule)
            }
            .padding(.leading, 70)
            .padding(.top, 150)
            // the folded-down corner
            FoldShape(ear: ear)
                .fill(LinearGradient(colors: [fold, paper], startPoint: .bottomLeading, endPoint: .topTrailing))
                .shadow(color: .black.opacity(0.25), radius: 8, x: -6, y: 8)
                .frame(width: w, height: h)
        }
        .frame(width: w, height: h)
    }

    func bar(width: CGFloat, color: Color, height: CGFloat = 24) -> some View {
        Capsule().fill(color).frame(width: width, height: height)
    }
}

/// Page rectangle with the top-right corner cut off diagonally.
struct PageShape: Shape {
    let ear: CGFloat
    func path(in r: CGRect) -> Path {
        let c: CGFloat = 34
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + ear))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The triangle of paper folded over the cut corner.
struct FoldShape: Shape {
    let ear: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear + 10, y: r.minY + ear - 10),
                       control: CGPoint(x: r.maxX - ear * 0.55, y: r.minY + ear * 1.05))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.minY),
                       control: CGPoint(x: r.maxX - ear * 1.05, y: r.minY + ear * 0.55))
        p.closeSubpath()
        return p
    }
}

@MainActor func render() {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
MainActor.assumeIsolated { render() }
