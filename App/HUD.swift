import GullfireKit
import SwiftUI

/// The flight readout: SF Mono, uppercase, in the palette's line colour, with no
/// panels. Warnings are text, never colour alone. Values are exposed to VoiceOver as one element.
struct HUDView: View {
    let model: AppModel

    private var ink: Color {
        let c = model.palette.line
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.hud.mode)
                if !model.hud.endless.isEmpty { Text(model.hud.endless) }
                Text(String(format: "ALTITUDE %04.0f FT", model.hud.altitudeFt))
                if let target = model.hud.heightTargetFt {
                    Text(String(format: "HEIGHT TARGET %04.0f FT", target))
                } else {
                    Text(model.hud.heightOffsetM == 0 ? "HEIGHT 0 M" : String(format: "HEIGHT %+.0f M", model.hud.heightOffsetM))
                }
                if model.mouseFlight { Text("MOUSE ON / ESC TO RELEASE") }
                if model.pickMode { Text(model.pickLine) }
                Text(String(format: "GROUND SPEED %04.0f KTS", model.hud.speedKt))
                Text(String(format: "HEADING %03.0f°", model.hud.headingDeg))
                Text(String(format: "POSITION %.4f %@ %.4f %@", abs(model.hud.latitude),
                            model.hud.latitude >= 0 ? "N" : "S",
                            abs(model.hud.longitude), model.hud.longitude >= 0 ? "E" : "W"))
            }
            if model.hud.proximityWarning {
                Text("PROXIMITY WARNING / AUTOMATIC CORRECTION")
            }
            if model.hud.boundaryWarning {
                Text("BOUNDARY / RETURNING")
            }
            if let notice = model.notice {
                Text(notice)
            }
            if model.showPerformance {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "RES    %@", model.perf.resolution))
                    Text(String(format: "FPS    %.1f", model.perf.fps))
                    Text(String(format: "WORST  %.1f ms", model.perf.frameWorstMs))
                    Text(String(format: "GPU    %.2f ms", model.perf.gpuMs))
                    Text(String(format: "MEM    %.0f MB", model.perf.footprintMB))
                }
            }
            if let problem = model.problem {
                Text(problem).opacity(0.7)
            }
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(ink)
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// The mode notice on its own, for when the HUD is off: the endless line while endless flight is on, the mouse notice
/// while the pointer is taken (it is hidden and frozen, so the screen must say why and how to get it back), and any
/// short notice. Text, in the HUD's ink, one line each.
struct ModeNoticeView: View {
    let model: AppModel

    var body: some View {
        let c = model.palette.line
        VStack(alignment: .leading, spacing: 4) {
            if !model.hud.endless.isEmpty { Text(model.hud.endless) }
            if model.mouseFlight { Text("MOUSE ON / ESC TO RELEASE") }
            if model.pickMode { Text(model.pickLine) }
            if let notice = model.notice { Text(notice) }
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}
