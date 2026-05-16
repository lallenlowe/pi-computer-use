import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

struct BridgeFailure: Error {
	let message: String
	let code: String
}

final class AXRefStore {
	private var nextId: UInt64 = 0
	private var windows: [String: AXUIElement] = [:]
	private var elements: [String: AXUIElement] = [:]

	func storeWindow(_ window: AXUIElement) -> String {
		nextId += 1
		let ref = "w\(nextId)"
		windows[ref] = window
		return ref
	}

	func storeElement(_ element: AXUIElement) -> String {
		nextId += 1
		let ref = "e\(nextId)"
		elements[ref] = element
		return ref
	}

	func window(for ref: String) -> AXUIElement? {
		windows[ref]
	}

	func element(for ref: String) -> AXUIElement? {
		elements[ref]
	}
}

private struct CGWindowCandidate {
	let windowId: UInt32
	let title: String
	let bounds: CGRect
	let isOnscreen: Bool
}

final class Box<T> {
	var value: T
	init(_ value: T) {
		self.value = value
	}
}

// NOTE: this used to host InputSuppressionGuard, a global CGEventTap that
// swallowed the user's keyboard/mouse while the browser-bootstrap AppleScript
// raced to open a fresh window. Every input op now posts per-PID via
// CGEventPostToPid and never raises a window, so the bootstrap and the
// suppression tap are gone.

/// Mouse button label for click-ring effect coloring.
enum CursorEffectButton: String {
	case left, right, middle

	static func from(_ cg: CGMouseButton) -> CursorEffectButton {
		switch cg {
		case .right: return .right
		case .center: return .middle
		default: return .left
		}
	}

	var color: NSColor {
		switch self {
		// Magenta tail of the cursor gradient. Reads as a definite
		// "action happened here" without competing with the cursor.
		case .left: return NSColor(calibratedRed: 0.914, green: 0.180, blue: 0.910, alpha: 1.0)
		// Warm red for right-click; rare, semantically distinct.
		case .right: return NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1.0)
		// Neutral gray for middle-click.
		case .middle: return NSColor(calibratedWhite: 0.55, alpha: 1.0)
		}
	}
}

/// One expanding-ring "click happened here" effect. Multi-click (e.g.
/// double, triple) is represented as several effects with staggered
/// `startTime` offsets so the rings ripple out one after the other.
struct ClickRingEffect {
	let id: UUID
	let globalPoint: CGPoint
	let button: CursorEffectButton
	let startTime: CFTimeInterval
	// Bumped from 0.350 → 0.550 so a single click is easier to catch
	// visually when the user isn't already looking at the cursor.
	static let duration: CFTimeInterval = 0.550

	func isFinished(at now: CFTimeInterval) -> Bool {
		return now - startTime >= ClickRingEffect.duration
	}
}

/// One "text was entered here" flash effect. Either anchored to a
/// global rect (the focused element's bounds) or `nil` to render as a
/// small pill at the last cursor location. Two modes share the same
/// timing so they're animated by the same tick loop.
struct TypeFlashEffect {
	let id: UUID
	let globalRect: CGRect?
	let fallbackCursorPoint: CGPoint?
	let startTime: CFTimeInterval
	// Bumped from 0.650 → 0.950. Hold + fade envelope rebalanced in
	// drawTypeFlashes so the extra time lands mostly in the hold,
	// keeping the flash feeling stable rather than lingering.
	static let duration: CFTimeInterval = 0.950

	func isFinished(at now: CFTimeInterval) -> Bool {
		return now - startTime >= TypeFlashEffect.duration
	}
}

/// One "agent pressed a key" badge effect. Anchored to either a
/// global point (focused element's frame midpoint or fallback cursor)
/// and rendered as a small rounded pill containing the key label.
/// Slightly longer-lived than a click ring so chord text is readable.
struct KeypressBadgeEffect {
	let id: UUID
	let globalPoint: CGPoint
	let label: String
	let startTime: CFTimeInterval
	// Bumped from 0.700 → 1.100. Envelope in drawKeypressBadges keeps
	// the 80ms fade-in and rebalances the rest as 720ms hold +
	// 300ms fade-out so chord labels stay readable longer without
	// the fade feeling stretched.
	static let duration: CFTimeInterval = 1.100

	func isFinished(at now: CFTimeInterval) -> Bool {
		return now - startTime >= KeypressBadgeEffect.duration
	}
}

/// One "agent scrolled here" effect. Anchored at the scroll point
/// (cursor location at the moment scrollWheel was posted) with a
/// direction vector encoded as a unit-ish (dx, dy). Magnitude is
/// implicit — the controller derives chevron count from the raw
/// delta passed at trigger time so a small scroll renders a single
/// chevron and a large scroll fans out a few stacked ones.
///
/// Color is teal-green per the documented agent action color
/// language (scroll = teal-green, keyboard = sky-blue, mouse =
/// button-color, focus/window = amber).
struct ScrollEffect {
	let id: UUID
	let globalPoint: CGPoint
	/// Direction component along x (positive = right). Normalized to
	/// the unit vector at construction time.
	let dx: CGFloat
	/// Direction component along y (positive = down in CG global coords).
	let dy: CGFloat
	/// Number of chevrons to stamp (1–3). Driven by scroll magnitude.
	let chevronCount: Int
	let startTime: CFTimeInterval
	// Bumped from 0.420 → 0.700. Chevrons travel outward over the
	// full lifetime; the longer window gives stacked chevrons more
	// time to fan out before the trailing ones start fading.
	static let duration: CFTimeInterval = 0.700

	func isFinished(at now: CFTimeInterval) -> Bool {
		return now - startTime >= ScrollEffect.duration
	}
}

/// One "agent operated on this window" outline pulse. Anchored to a
/// global window frame (CG coords, top-left origin) and rendered as
/// two outward-expanding rounded outlines that fade out together.
/// Used by surfaceWindow / launchApp({activate:true}) / setWindowFrame
/// to give the user an unmistakable "target acquired / window
/// arranged" signal that ties the visible window state change to the
/// agent's intent. Color is amber/gold per the documented action
/// color language (focus/window state = amber).
struct WindowPulseEffect {
	let id: UUID
	let globalFrame: CGRect
	let startTime: CFTimeInterval
	// Bumped from 0.900 → 1.400. Window pulses fire across Spaces
	// transitions and app-activation flashes — the user's eye has
	// to chase several things at once, so the cue needs more time
	// to register. Envelope rebalanced in drawWindowPulses to keep
	// the hold prominent and only stretch the fade slightly.
	static let duration: CFTimeInterval = 1.400

	func isFinished(at now: CFTimeInterval) -> Bool {
		return now - startTime >= WindowPulseEffect.duration
	}
}

/// Pre-converted, per-screen-local effect descriptors that the view
/// renders on each draw. The OverlayController owns effects in global
/// CG coords and walks them per-screen at render time, mirroring how
/// it handles `cursorPoint`.
struct ScreenLocalClickRing {
	let localPoint: CGPoint
	let button: CursorEffectButton
	let age: CFTimeInterval
}

struct ScreenLocalTypeFlash {
	let localRect: CGRect
	let age: CFTimeInterval
}

struct ScreenLocalKeypressBadge {
	let localPoint: CGPoint
	let label: String
	let age: CFTimeInterval
}

struct ScreenLocalScrollEffect {
	let localPoint: CGPoint
	let dx: CGFloat
	let dy: CGFloat
	let chevronCount: Int
	let age: CFTimeInterval
}

struct ScreenLocalWindowPulse {
	let localRect: CGRect
	let age: CFTimeInterval
}

/// Custom NSView that paints the agent's virtual cursor at the
/// configured screen-local point. Renders a paper-airplane shape
/// translated from `assets/cursor.svg` (600x600 viewBox) into native
/// NSBezierPath calls so we don't have to ship a sidecar asset and
/// the shape scales crisply at any cursorSize. SVG (122.5, 101) is
/// the click hotspot anchor.
///
/// The view also paints transient "effect" decorations behind the
/// cursor - click rings and type flashes. The OverlayController
/// pushes the screen-local descriptors here on each tick.
final class OverlayCursorView: NSView {
	var cursorPoint: CGPoint? = nil
	var cursorSize: CGFloat = 28
	// Alpha for the cursor glyph and its drop shadow. Driven by the
	// OverlayController's idle-fade logic so the cursor melts away
	// after the agent stops acting instead of squatting on screen
	// for the rest of the pi session. Effects (clicks, type flashes,
	// keypress badges, scroll chevrons, window pulses) ignore this
	// alpha and fade on their own envelopes - they're transient
	// announcements, not persistent state.
	var cursorAlpha: CGFloat = 1.0
	var clickRings: [ScreenLocalClickRing] = []
	var typeFlashes: [ScreenLocalTypeFlash] = []
	var keypressBadges: [ScreenLocalKeypressBadge] = []
	var scrollEffects: [ScreenLocalScrollEffect] = []
	var windowPulses: [ScreenLocalWindowPulse] = []

	// SVG viewBox dims and the in-viewBox coords of the click hotspot.
	// Kept as named constants so the path-translation math reads
	// cleanly and survives future shape edits without arithmetic
	// drift between the path data and the anchor positioning.
	private static let svgViewBoxSize: CGFloat = 600.0
	private static let svgAnchorX: CGFloat = 122.5
	private static let svgAnchorY: CGFloat = 101.0

	override var isFlipped: Bool { false }

	override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext else { return }

		// Effects render *behind* the cursor so the cursor never gets
		// occluded by the very thing it's announcing.
		drawWindowPulses(ctx)
		drawTypeFlashes(ctx)
		drawClickRings(ctx)
		drawScrollEffects(ctx)
		drawKeypressBadges(ctx)

		guard let point = cursorPoint else { return }
		// Honor the idle-fade alpha. cursorAlpha <= 0 means "agent
		// idle long enough to fully fade" - skip drawing entirely so
		// we don't waste a save/restore + path build per tick.
		if cursorAlpha <= 0.0 { return }

		// scale = cursorSize / svgViewBoxSize so the rendered icon is
		// `cursorSize` points wide along its viewBox dimension.
		let scale = cursorSize / OverlayCursorView.svgViewBoxSize
		let path = OverlayCursorView.makeCursorPath(scale: scale)

		// Translate so the SVG anchor lands at `point`. The path is
		// authored y-flipped inside makeCursorPath (SVG top-down ->
		// AppKit bottom-up), so the SVG y of the anchor maps to the
		// (svgViewBoxSize - svgAnchorY) offset in view coords.
		ctx.saveGState()
		ctx.translateBy(
			x: point.x - OverlayCursorView.svgAnchorX * scale,
			y: point.y - (OverlayCursorView.svgViewBoxSize - OverlayCursorView.svgAnchorY) * scale
		)

		// Apply the idle-fade alpha globally for cursor + shadow so
		// the whole glyph fades together. The shadow's own opacity
		// (0.35) gets multiplied through this layer alpha.
		ctx.setAlpha(cursorAlpha)

		// Soft drop shadow under the whole shape.
		ctx.saveGState()
		ctx.setShadow(
			offset: CGSize(width: 0, height: -1.0 * scale * 8),
			blur: scale * 12,
			color: NSColor.black.withAlphaComponent(0.35).cgColor
		)

		// Fill with the SVG's 3-stop gradient (sky blue -> purple ->
		// magenta). Gradient direction in SVG userSpaceOnUse coords is
		// from (80, 180) to (500, 290). We map those into our scaled +
		// y-flipped coordinate space inline.
		let gradient = CGGradient(
			colorsSpace: CGColorSpaceCreateDeviceRGB(),
			colors: [
				NSColor(calibratedRed: 0.247, green: 0.710, blue: 0.984, alpha: 1.0).cgColor,
				NSColor(calibratedRed: 0.612, green: 0.435, blue: 0.957, alpha: 1.0).cgColor,
				NSColor(calibratedRed: 0.914, green: 0.180, blue: 0.910, alpha: 1.0).cgColor,
			] as CFArray,
			locations: [0.0, 0.55, 1.0]
		)
		if let gradient = gradient {
			ctx.saveGState()
			ctx.addPath(path.compatibleCGPath)
			ctx.clip()
			let startSVG = NSPoint(x: 80, y: 180)
			let endSVG = NSPoint(x: 500, y: 290)
			func s(_ p: NSPoint) -> CGPoint {
				return CGPoint(x: p.x * scale, y: (OverlayCursorView.svgViewBoxSize - p.y) * scale)
			}
			ctx.drawLinearGradient(
				gradient,
				start: s(startSVG),
				end: s(endSVG),
				options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
			)
			ctx.restoreGState()
		}
		ctx.restoreGState()

		ctx.restoreGState()
	}

	/// Render every currently-active click ring as an expanding,
	/// fading stroked circle. Radius and alpha are pure functions of
	/// effect age so the controller can swap descriptors freely without
	/// us holding any local animation state.
	private func drawClickRings(_ ctx: CGContext) {
		for ring in clickRings {
			let t = max(0.0, min(1.0, ring.age / ClickRingEffect.duration))
			// Radius grows from 0 to ~cursorSize as the ring ages.
			let maxRadius = cursorSize * 1.05
			let eased = OverlayController.easeOutCubic(t)
			let radius = CGFloat(eased) * maxRadius
			// Alpha decays linearly from 0.85 to 0 over the lifetime.
			let alpha = CGFloat(0.85 * (1.0 - t))
			if radius < 0.5 || alpha <= 0 { continue }
			let rect = NSRect(
				x: ring.localPoint.x - radius,
				y: ring.localPoint.y - radius,
				width: radius * 2,
				height: radius * 2
			)
			let circle = NSBezierPath(ovalIn: rect)
			ring.button.color.withAlphaComponent(alpha).setStroke()
			circle.lineWidth = 2.5
			circle.stroke()
		}
	}

	/// Render every currently-active type flash as a 2pt rounded
	/// rectangle outline. Envelope (at 0.950s lifetime): ~95ms fade
	/// in / ~620ms hold / ~235ms fade out — rebalanced from the
	/// shorter 0.650s timing so the hold reads stable rather than
	/// the fade feeling stretched.
	private func drawTypeFlashes(_ ctx: CGContext) {
		for flash in typeFlashes {
			let t = max(0.0, min(1.0, flash.age / TypeFlashEffect.duration))
			let alpha: CGFloat
			if t < 0.10 {
				alpha = CGFloat(t / 0.10)
			} else if t < 0.75 {
				alpha = 1.0
			} else {
				alpha = CGFloat((1.0 - t) / 0.25)
			}
			if alpha <= 0 { continue }
			let path = NSBezierPath(roundedRect: flash.localRect, xRadius: 4, yRadius: 4)
			// Sky blue (matches the cursor gradient start) so the flash
			// reads as part of the same visual language as the cursor.
			NSColor(calibratedRed: 0.247, green: 0.710, blue: 0.984, alpha: alpha * 0.95).setStroke()
			path.lineWidth = 2.0
			path.stroke()
		}
	}

	/// Render every currently-active scroll effect as a stack of
	/// stroked chevrons pointing in the scroll direction. Chevrons
	/// translate outward from the anchor point along the scroll
	/// vector and fade as they age — the visual reads as "motion
	/// happened here, this way." Teal-green per the action color
	/// language (scroll). Magnitude bumps the count from 1 to 3.
	private func drawScrollEffects(_ ctx: CGContext) {
		for effect in scrollEffects {
			let t = max(0.0, min(1.0, effect.age / ScrollEffect.duration))
			let eased = OverlayController.easeOutCubic(t)
			// Alpha: hold near full for the first 30%, fade out across
			// the remaining 70%. Keeps the cue legible even on a quick
			// scroll.
			let alpha: CGFloat
			if t < 0.30 {
				alpha = 1.0
			} else {
				alpha = CGFloat((1.0 - t) / 0.70)
			}
			if alpha <= 0 { continue }

			let chevronSize: CGFloat = 14
			let travel: CGFloat = chevronSize * 1.8
			// Stack chevrons along the scroll direction. First chevron
			// is closest to the anchor; subsequent ones lag behind.
			let color = NSColor(calibratedRed: 0.196, green: 0.804, blue: 0.604, alpha: alpha)
			color.setStroke()

			for i in 0..<max(1, effect.chevronCount) {
				let stagger = CGFloat(i) * 0.18
				let localT = max(0.0, min(1.0, eased - stagger))
				let offset = travel * localT + CGFloat(i) * chevronSize * 0.9
				let centerX = effect.localPoint.x + effect.dx * offset
				let centerY = effect.localPoint.y + effect.dy * offset

				// Chevron geometry: V shape pointing in (dx, dy). Two
				// strokes meeting at the tip. Tip lies on (centerX, centerY)
				// along the travel vector; tails fan out perpendicular.
				let halfWidth: CGFloat = chevronSize * 0.55
				let tipExtension: CGFloat = chevronSize * 0.45
				// Perpendicular vector (rotate scroll dir 90°).
				let perpX = -effect.dy
				let perpY = effect.dx
				let tipX = centerX + effect.dx * tipExtension
				let tipY = centerY + effect.dy * tipExtension
				let leftX = centerX - effect.dx * tipExtension + perpX * halfWidth
				let leftY = centerY - effect.dy * tipExtension + perpY * halfWidth
				let rightX = centerX - effect.dx * tipExtension - perpX * halfWidth
				let rightY = centerY - effect.dy * tipExtension - perpY * halfWidth

				let path = NSBezierPath()
				path.move(to: NSPoint(x: leftX, y: leftY))
				path.line(to: NSPoint(x: tipX, y: tipY))
				path.line(to: NSPoint(x: rightX, y: rightY))
				path.lineWidth = 2.5
				path.lineCapStyle = .round
				path.lineJoinStyle = .round
				path.stroke()
			}
		}
	}

	/// Render every currently-active keypress badge as a small rounded
	/// pill containing the chord label ("↵", "Cmd+L", "Esc"). Same
	/// fade envelope as type flashes so the visual language is
	/// consistent. Pill is sky-blue filled with white text - blue is
	/// the documented "keyboard input" color in the agent action
	/// language.
	private func drawKeypressBadges(_ ctx: CGContext) {
		for badge in keypressBadges {
			let t = max(0.0, min(1.0, badge.age / KeypressBadgeEffect.duration))
			// Envelope: 80ms in / 720ms hold / 300ms out. Hold-heavier
			// than type-flash since chord text takes a beat to read; the
			// extra duration vs the earlier 80/420/200 envelope all
			// lands in the hold + a small fade bump.
			let alpha: CGFloat
			let fadeIn = 0.080 / KeypressBadgeEffect.duration
			let holdEnd = (0.080 + 0.720) / KeypressBadgeEffect.duration
			if t < fadeIn {
				alpha = CGFloat(t / fadeIn)
			} else if t < holdEnd {
				alpha = 1.0
			} else {
				alpha = CGFloat((1.0 - t) / (1.0 - holdEnd))
			}
			if alpha <= 0 { continue }

			// Lay out the text. SF Mono so chord labels read crisp
			// at the small size we need.
			let attrs: [NSAttributedString.Key: Any] = [
				.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
				.foregroundColor: NSColor.white.withAlphaComponent(alpha),
			]
			let attributed = NSAttributedString(string: badge.label, attributes: attrs)
			let textSize = attributed.size()

			// Pill geometry: padding around the text, rounded ends.
			let padX: CGFloat = 8
			let padY: CGFloat = 4
			let pillWidth = ceil(textSize.width) + padX * 2
			let pillHeight = ceil(textSize.height) + padY * 2
			let radius = pillHeight / 2

			// Anchor: 14pt right and 22pt up from the badge point so the
			// pill floats just above-right of the cursor / focused
			// element midpoint without overlapping the cursor sprite.
			let originX = badge.localPoint.x + 14
			let originY = badge.localPoint.y + 22
			let pillRect = NSRect(x: originX, y: originY, width: pillWidth, height: pillHeight)
			let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)

			// Fill: sky-blue (matches the cursor gradient start +
			// type-flash stroke). White text rides on top.
			NSColor(calibratedRed: 0.247, green: 0.710, blue: 0.984, alpha: alpha * 0.95).setFill()
			pillPath.fill()

			// Subtle white outline so the pill stays readable on
			// matching-color backgrounds.
			NSColor.white.withAlphaComponent(alpha * 0.35).setStroke()
			pillPath.lineWidth = 1.0
			pillPath.stroke()

			let textOrigin = NSPoint(x: originX + padX, y: originY + padY)
			attributed.draw(at: textOrigin)
		}
	}

	/// Render every currently-active window pulse as a pair of
	/// expanding rounded outlines around the window's frame. Two
	/// concentric strokes — the inner one slightly inset, the outer
	/// growing outward over the lifetime — read as a "target
	/// acquired" pulse rather than a single static outline. Color is
	/// amber/gold per the documented action color language
	/// (focus / window state changes).
	private func drawWindowPulses(_ ctx: CGContext) {
		for pulse in windowPulses {
			let t = max(0.0, min(1.0, pulse.age / WindowPulseEffect.duration))
			let eased = OverlayController.easeOutCubic(t)

			// Two-pulse envelope (at 1.400s lifetime): 40% hold then
			// 60% fade-out. Hold prominent so the cue survives Spaces
			// transitions and app-activation flashes; long enough fade
			// to register without overstaying the moment of action.
			let alpha: CGFloat
			if t < 0.40 {
				alpha = 1.0
			} else {
				alpha = CGFloat((1.0 - t) / 0.60)
			}
			if alpha <= 0 { continue }

			// Outer pulse: starts flush with the frame and expands
			// outward by up to ~12pt as it ages.
			let expand: CGFloat = 12.0 * CGFloat(eased)
			let outerRect = pulse.localRect.insetBy(dx: -expand, dy: -expand)
			let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 10, yRadius: 10)

			// Amber/gold (the documented "focus / window state"
			// color in the agent action language).
			let amber = NSColor(calibratedRed: 1.000, green: 0.749, blue: 0.247, alpha: alpha)
			amber.setStroke()
			outerPath.lineWidth = 3.0
			outerPath.stroke()

			// Inner pulse: starts inset and contracts toward the
			// frame as it ages. Two opposing strokes give the
			// "target reticule closing in" feel without needing
			// crosshairs or any extra ornament.
			let inset: CGFloat = 6.0 * CGFloat(1.0 - eased)
			let innerRect = pulse.localRect.insetBy(dx: inset, dy: inset)
			let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 8, yRadius: 8)
			amber.withAlphaComponent(alpha * 0.55).setStroke()
			innerPath.lineWidth = 1.5
			innerPath.stroke()
		}
	}

	/// Build the cursor outline as an NSBezierPath at the given scale.
	/// Path commands are the SVG `d` attribute from assets/cursor.svg,
	/// translated to NSBezierPath calls. SVG y is top-down; we y-flip
	/// here so the resulting path is in standard AppKit (bottom-up)
	/// coords ready to translate into the view.
	private static func makeCursorPath(scale: CGFloat) -> NSBezierPath {
		func s(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
			return NSPoint(x: x * scale, y: (svgViewBoxSize - y) * scale)
		}
		// Convert an SVG quadratic Bezier (one control point) to
		// NSBezierPath's cubic form via the standard 2/3 control-point
		// formula: c1 = S + 2/3*(C - S); c2 = E + 2/3*(C - E).
		func q(_ path: NSBezierPath, control cx: CGFloat, _ cy: CGFloat, end ex: CGFloat, _ ey: CGFloat) {
			let S = path.currentPoint
			let C = s(cx, cy)
			let E = s(ex, ey)
			let c1 = NSPoint(x: S.x + (2.0/3.0) * (C.x - S.x), y: S.y + (2.0/3.0) * (C.y - S.y))
			let c2 = NSPoint(x: E.x + (2.0/3.0) * (C.x - E.x), y: E.y + (2.0/3.0) * (C.y - E.y))
			path.curve(to: E, controlPoint1: c1, controlPoint2: c2)
		}
		let path = NSBezierPath()
		path.move(to: s(122.5, 101.0))
		path.line(to: s(440.6, 255.9))
		q(path, control: 490, 280, end: 436.7, 293.6)
		path.line(to: s(288.9, 331.4))
		q(path, control: 255, 340, end: 249.4, 374.5)
		path.line(to: s(224.8, 525.4))
		q(path, control: 220, 555, end: 212.5, 526.0)
		path.line(to: s(106.3, 114.2))
		q(path, control: 100, 90, end: 122.5, 101.0)
		path.close()
		return path
	}
}

extension NSBezierPath {
	/// Bridge to CGPath so we can use the path with Core Graphics calls
	/// (clipping, gradients). Named `compatibleCGPath` to avoid
	/// shadowing the Apple-provided `cgPath` available on macOS 14+;
	/// using our explicit conversion lets the same code path work even
	/// if SDK behavior shifts.
	var compatibleCGPath: CGPath {
		let cgPath = CGMutablePath()
		var points = [NSPoint](repeating: .zero, count: 3)
		for i in 0..<elementCount {
			let type = element(at: i, associatedPoints: &points)
			switch type {
			case .moveTo:
				cgPath.move(to: points[0])
			case .lineTo:
				cgPath.addLine(to: points[0])
			case .curveTo:
				cgPath.addCurve(to: points[2], control1: points[0], control2: points[1])
			case .closePath:
				cgPath.closeSubpath()
			@unknown default:
				break
			}
		}
		return cgPath
	}
}

/// Animation style for cursor moves. `arc` uses a quadratic Bézier
/// with a control point offset perpendicular to the travel vector for
/// natural, hand-like motion. `linear` is the same eased timing on a
/// straight line (still smoother than a snap). `off` snaps instantly.
enum OverlayAnimationStyle: String {
	case arc
	case linear
	case off

	init(_ raw: String?) {
		switch raw?.lowercased() {
		case "linear": self = .linear
		case "off", "none", "snap": self = .off
		default: self = .arc
		}
	}
}

/// In-flight cursor animation. Held by the OverlayController; mutated
/// only from main. We sample the current animated position every tick
/// so a `moveTo` arriving mid-flight can start its new tween from the
/// cursor's *visual* current position, which gives smooth direction
/// changes without explicit velocity matching.
struct CursorAnimation {
	let start: CGPoint
	let end: CGPoint
	let control: CGPoint
	let startTime: CFTimeInterval
	let duration: CFTimeInterval

	func point(at now: CFTimeInterval) -> CGPoint {
		let rawT = duration > 0 ? min(1.0, max(0.0, (now - startTime) / duration)) : 1.0
		let t = OverlayController.easeOutCubic(rawT)
		return OverlayController.quadraticBezier(start: start, control: control, end: end, t: CGFloat(t))
	}

	func isFinished(at now: CFTimeInterval) -> Bool {
		return now - startTime >= duration
	}
}

/// Owns the per-screen overlay windows that draw the agent's virtual
/// cursor. Lives entirely on main; all mutating methods must be called
/// from main (or routed there).
///
/// The overlay is gated by an explicit `enable()` call. `enable()`
/// also flips the helper from `.prohibited` to `.accessory` activation
/// policy because `.prohibited` apps cannot host any windows. This is
/// the one observable behavior change for users who turn the overlay
/// on. `.accessory` keeps the helper out of the dock and out of
/// cmd-tab, so it stays out of the user's way.
final class OverlayController {
	static let shared = OverlayController()

	private var enabled = false
	private var windows: [NSWindow] = []
	private var views: [OverlayCursorView] = []
	private var lastGlobalPoint: CGPoint? = nil
	private var currentDisplayedGlobalPoint: CGPoint? = nil
	private var animation: CursorAnimation? = nil
	private var clickRings: [ClickRingEffect] = []
	private var typeFlashes: [TypeFlashEffect] = []
	private var keypressBadges: [KeypressBadgeEffect] = []
	private var scrollEffects: [ScrollEffect] = []
	private var windowPulses: [WindowPulseEffect] = []
	private var displayTimer: Timer? = nil
	private var screenChangeObserver: NSObjectProtocol? = nil

	// PID of the app the agent is currently driving. Used by the
	// occlusion check to decide whether to render the cursor on each
	// tick: if the topmost window under the cursor doesn't belong to
	// this PID, the cursor and its effects are suppressed so the
	// agent's UI doesn't visually intrude on whatever the user has
	// brought to the foreground. Updated on every moveTo / trigger
	// call that supplies an ownerPid.
	private var lastTargetPid: pid_t? = nil
	private let helperPid: pid_t = getpid()

	// Animation tunables. Settable from the bridge so the TS-side
	// config can drive them; defaults match a quick, restrained motion.
	var animationStyle: OverlayAnimationStyle = .arc
	var animationDuration: CFTimeInterval = 0.180

	// Idle-fade tunables. The cursor used to persist on screen for
	// the rest of the pi session - visually distracting clutter long
	// after the agent stopped acting. After `cursorIdleFadeStart`
	// seconds of no agent activity (no moveTo, no trigger*), the
	// cursor fades to fully invisible over `cursorIdleFadeDuration`
	// seconds. Next agent action snaps it back instantly.
	//
	// Activity = anything the agent intentionally did on screen:
	// move/click/type/keypress/scroll/drag/focus-sync/window-pulse.
	// Every trigger* call hits bumpActivity, so any in-flight effect
	// (scroll chevrons, keypress badge, window pulse, type flash,
	// click ring) resets the idle clock - the cursor stays put
	// while the agent is still doing stuff.
	var cursorIdleFadeStart: CFTimeInterval = 20.0
	var cursorIdleFadeDuration: CFTimeInterval = 0.5

	// Timestamp of the most recent agent activity. nil means we have
	// no idle clock yet (overlay just enabled, or fade completed).
	private var lastActivityTime: CFTimeInterval? = nil

	// When true, the overlay hides itself any time the agent's target
	// app is not the topmost window under the cursor. Default on; set
	// to false to restore the always-visible legacy behavior.
	var occlusionAware: Bool = true

	private init() {}

	func enable() {
		if enabled { return }
		enabled = true
		if NSApp.activationPolicy() != .accessory {
			NSApp.setActivationPolicy(.accessory)
		}
		rebuildWindows()
		screenChangeObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.rebuildWindows()
		}
		if let point = lastGlobalPoint {
			moveTo(globalPoint: point)
		}
	}

	func disable() {
		if !enabled { return }
		enabled = false
		cancelAnimation()
		clickRings.removeAll()
		typeFlashes.removeAll()
		keypressBadges.removeAll()
		scrollEffects.removeAll()
		windowPulses.removeAll()
		currentDisplayedGlobalPoint = nil
		if let observer = screenChangeObserver {
			NotificationCenter.default.removeObserver(observer)
			screenChangeObserver = nil
		}
		for window in windows {
			window.orderOut(nil)
		}
		windows.removeAll()
		views.removeAll()
		// Drop back to invisible-helper mode. We don't bother flipping
		// activation policy back to .prohibited because that's a one-way
		// transition for some AppKit machinery; .accessory with no windows
		// is functionally invisible.
	}

	func isEnabled() -> Bool { enabled }

	/// Move the cursor to a global screen coordinate expressed in
	/// CGEvent / Quartz convention (origin top-left of primary screen).
	/// Internally tweens (or snaps when animation is off) to the new
	/// point. Returns immediately; the visual catches up over the
	/// animation duration so the actual click never blocks on motion.
	///
	/// `ownerPid` is the PID of the app the agent is acting on; passing
	/// it lets the occlusion check suppress rendering when the user
	/// brings a different window to the foreground.
	///
	/// `instant` short-circuits the tween and snaps the overlay to
	/// the new point. Used by the drag path where waypoints arrive
	/// every ~8–12ms — way faster than the default 180ms tween, so a
	/// tweened follow would lag visibly behind the real cursor. Click,
	/// move_mouse, and AX paths keep the default tweened behaviour.
	func moveTo(globalPoint: CGPoint, ownerPid: pid_t? = nil, instant: Bool = false) {
		lastGlobalPoint = globalPoint
		if let ownerPid = ownerPid { lastTargetPid = ownerPid }
		if !enabled { return }
		// Reset the idle clock - cursor pops back to full opacity
		// immediately on any agent move.
		bumpActivity()

		// If we have no prior position, animation is off, or caller
		// asked for an instant snap (drag waypoints), just snap. The
		// drag handler holds the AppKit main thread inside a tight
		// usleep loop, so without a synchronous redraw the run loop
		// never gets a chance to paint between waypoints and the user
		// only sees the cursor jump to the last position. Force a
		// synchronous `view.display()` in the instant path so each
		// waypoint actually renders before the next CGEvent post.
		guard !instant, animationStyle != .off, let from = currentDisplayedGlobalPoint else {
			cancelAnimation()
			renderGlobalPoint(globalPoint, forceSynchronousDisplay: instant)
			currentDisplayedGlobalPoint = globalPoint
			return
		}

		// Compute start position: if already animating, sample from the
		// in-flight animation so direction changes are visually smooth.
		let now = CACurrentMediaTime()
		let realStart = animation?.point(at: now) ?? from

		// Trivial-distance fast path: snap to avoid spending a frame on a
		// 1px tween.
		let dx = globalPoint.x - realStart.x
		let dy = globalPoint.y - realStart.y
		let distance = sqrt(dx * dx + dy * dy)
		if distance < 2 {
			cancelAnimation()
			renderGlobalPoint(globalPoint)
			currentDisplayedGlobalPoint = globalPoint
			return
		}

		let control: CGPoint
		switch animationStyle {
		case .linear:
			control = CGPoint(x: (realStart.x + globalPoint.x) / 2, y: (realStart.y + globalPoint.y) / 2)
		case .arc, .off:
			// Arc style. Place the control point at the midpoint plus an
			// offset perpendicular to the travel vector. Bow height grows
			// with sqrt(distance) so short hops are nearly straight and
			// long jumps arc visibly without going off-screen.
			let midX = (realStart.x + globalPoint.x) / 2
			let midY = (realStart.y + globalPoint.y) / 2
			let perpX = -dy / distance
			let perpY = dx / distance
			let bow = sqrt(distance) * 6
			control = CGPoint(x: midX + perpX * bow, y: midY + perpY * bow)
		}

		animation = CursorAnimation(
			start: realStart,
			end: globalPoint,
			control: control,
			startTime: now,
			duration: animationDuration
		)
		ensureDisplayTimer()
	}

	/// Trigger an expanding click-ring effect at the given global
	/// CG point. Multi-click stamps multiple rings spaced 60ms apart
	/// so the user sees them ripple. No-op when the overlay is off.
	func triggerClickRing(globalPoint: CGPoint, button: CursorEffectButton, count: Int = 1, ownerPid: pid_t? = nil) {
		if let ownerPid = ownerPid { lastTargetPid = ownerPid }
		if !enabled { return }
		bumpActivity()
		let now = CACurrentMediaTime()
		let stamped = max(1, min(5, count))
		for i in 0..<stamped {
			clickRings.append(ClickRingEffect(
				id: UUID(),
				globalPoint: globalPoint,
				button: button,
				startTime: now + CFTimeInterval(i) * 0.060
			))
		}
		ensureDisplayTimer()
	}

	/// Trigger a type-flash effect. Pass `globalRect` when the focused
	/// element's bounds are known (preferred), otherwise pass nil and
	/// the view will draw a small pill near the last cursor position
	/// so the user still gets some signal.
	func triggerTypeFlash(globalRect: CGRect?, ownerPid: pid_t? = nil) {
		if let ownerPid = ownerPid { lastTargetPid = ownerPid }
		if !enabled { return }
		bumpActivity()
		let now = CACurrentMediaTime()
		typeFlashes.append(TypeFlashEffect(
			id: UUID(),
			globalRect: globalRect,
			fallbackCursorPoint: globalRect == nil ? lastGlobalPoint : nil,
			startTime: now
		))
		ensureDisplayTimer()
	}

	/// Trigger a keypress-badge effect. Anchored to `globalPoint` if
	/// supplied (typically the focused element's frame midpoint),
	/// otherwise to the last known cursor position. No-op when no
	/// anchor exists at all - we'd rather drop the visual than render
	/// at (0,0).
	func triggerKeypressBadge(label: String, globalPoint: CGPoint? = nil, ownerPid: pid_t? = nil) {
		if let ownerPid = ownerPid { lastTargetPid = ownerPid }
		if !enabled { return }
		bumpActivity()
		let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return }
		guard let anchor = globalPoint ?? lastGlobalPoint else { return }
		let now = CACurrentMediaTime()
		keypressBadges.append(KeypressBadgeEffect(
			id: UUID(),
			globalPoint: anchor,
			label: trimmed,
			startTime: now
		))
		ensureDisplayTimer()
	}

	/// Trigger a scroll-effect at the given anchor with the raw
	/// scroll deltas. Deltas are converted to a unit direction vector
	/// internally; magnitude is mapped to a chevron count (1–3) so
	/// small scrolls show one chevron and big bursts show a stack.
	/// No-op when the overlay is off or both deltas are zero.
	func triggerScrollEffect(globalPoint: CGPoint, deltaX: Int, deltaY: Int, ownerPid: pid_t? = nil) {
		if let ownerPid = ownerPid { lastTargetPid = ownerPid }
		if !enabled { return }
		if deltaX == 0 && deltaY == 0 { return }
		bumpActivity()

		// Agent convention from the scroll tool docstring: positive
		// scrollY = scroll DOWN, negative = scroll UP.
		//
		// Chevrons are drawn in AppKit *view* coordinates (origin
		// bottom-left, +y up) because the view is not flipped.
		// convertGlobalToScreenLocal already flips the anchor point
		// from CG-global to AppKit-view space; here we just need the
		// direction vector to also be in AppKit terms. So scroll-down
		// (+150) -> chevrons should point downward on screen -> negative
		// y in AppKit view space. Hence the sign inversion.
		let vx = CGFloat(deltaX)
		let vy = CGFloat(-deltaY)
		let magnitude = sqrt(vx * vx + vy * vy)
		if magnitude < 0.5 { return }
		let ux = vx / magnitude
		let uy = vy / magnitude

		// Chevron count: 1 for tiny scrolls, 2 for medium, 3 for big.
		// Thresholds picked from observation - mouse wheel one notch
		// is usually deltaY = 8–20 in our scrollWheel calls.
		let chevrons: Int
		if magnitude >= 80 { chevrons = 3 }
		else if magnitude >= 25 { chevrons = 2 }
		else { chevrons = 1 }

		let now = CACurrentMediaTime()
		scrollEffects.append(ScrollEffect(
			id: UUID(),
			globalPoint: globalPoint,
			dx: ux,
			dy: uy,
			chevronCount: chevrons,
			startTime: now
		))
		ensureDisplayTimer()
	}

	/// Fire an amber outline pulse around a window's frame. Used by
	/// surfaceWindow / launchApp({activate:true}) / setWindowFrame to
	/// give the user a "target acquired" or "window arranged" cue tied
	/// to the agent's intent. The frame is in CG global coords (top-
	/// left origin); convertGlobalRectToScreenLocal flips it per-screen
	/// at render time. No-op when the overlay is off, when the frame
	/// has zero area (off-Space windows often report 0x0 from AX), or
	/// when the overlay is occluded by a non-target window.
	func triggerWindowPulse(globalFrame: CGRect, ownerPid: pid_t? = nil) {
		if let ownerPid = ownerPid { lastTargetPid = ownerPid }
		if !enabled { return }
		if globalFrame.width < 4 || globalFrame.height < 4 { return }
		// Window pulses are frame-anchored, not cursor-anchored, but
		// they still represent agent activity - keep the cursor (if
		// any) fresh while a pulse is in-flight.
		bumpActivity()
		windowPulses.append(WindowPulseEffect(
			id: UUID(),
			globalFrame: globalFrame,
			startTime: CACurrentMediaTime()
		))
		ensureDisplayTimer()
	}

	/// Reset the idle clock and (if needed) start the display timer
	/// so the cursor pops back to full opacity on the next tick. Cheap
	/// to call on every agent move/click/key/scroll/pulse - the work
	/// is one CFTimeInterval write plus an idempotent timer ensure.
	private func bumpActivity() {
		lastActivityTime = CACurrentMediaTime()
		ensureDisplayTimer()
	}

	/// Current idle-fade alpha for the cursor based on time since the
	/// last agent activity. Returns 1.0 inside the hold window,
	/// linearly fades to 0.0 across cursorIdleFadeDuration, then
	/// stays at 0.0. Returns 1.0 when we have no activity timestamp
	/// at all (overlay just enabled - first action will set it).
	private func currentCursorAlpha(now: CFTimeInterval) -> CGFloat {
		guard let last = lastActivityTime else { return 1.0 }
		let idle = now - last
		if idle <= cursorIdleFadeStart { return 1.0 }
		let fadeProgress = (idle - cursorIdleFadeStart) / cursorIdleFadeDuration
		if fadeProgress >= 1.0 { return 0.0 }
		return CGFloat(1.0 - fadeProgress)
	}

	/// True while the cursor is still partially visible OR still
	/// inside the hold window before fading begins. Keeps the 60Hz
	/// tick alive so the fade animation actually plays - if the timer
	/// shut down at the end of the last effect, the cursor would
	/// freeze at full alpha forever.
	private func cursorNeedsIdleTick(now: CFTimeInterval) -> Bool {
		guard lastActivityTime != nil else { return false }
		return currentCursorAlpha(now: now) > 0.0
	}

	private func ensureDisplayTimer() {
		if displayTimer != nil { return }
		// 60Hz tick. Timer on the main run loop is good enough for a
		// short tween and avoids the platform-specific complexity of
		// CVDisplayLink. tolerance: 0 keeps frames crisp.
		let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
			self?.tick()
		}
		timer.tolerance = 0
		RunLoop.main.add(timer, forMode: .common)
		displayTimer = timer
	}

	private func cancelAnimation() {
		animation = nil
		// Don't kill the timer if effects still need ticking OR the
		// idle-fade still needs ticks to paint the fade. Without the
		// fade check, the snap path of moveTo (no prior point) would
		// cancelAnimation -> kill the timer right after bumpActivity
		// scheduled it, leaving the cursor frozen at full alpha
		// forever. The timer shutdown logic in `tick` is the
		// canonical place that decides when to actually stop.
		if !hasActiveEffectsOrFade(now: CACurrentMediaTime()) {
			displayTimer?.invalidate()
			displayTimer = nil
		}
	}

	private func hasActiveEffects() -> Bool {
		return !clickRings.isEmpty || !typeFlashes.isEmpty || !keypressBadges.isEmpty || !scrollEffects.isEmpty || !windowPulses.isEmpty
	}

	/// hasActiveEffects + cursor still needing redraws (mid-fade or
	/// still in the hold window). Used by tick to decide whether to
	/// shut the 60Hz timer down. We need the cursor's idle fade to
	/// keep the timer alive even after all effects have culled,
	/// otherwise the tween stops at full alpha and the cursor squats
	/// on screen.
	private func hasActiveEffectsOrFade(now: CFTimeInterval) -> Bool {
		return hasActiveEffects() || cursorNeedsIdleTick(now: now)
	}

	private func tick() {
		let now = CACurrentMediaTime()

		if let anim = animation {
			let point = anim.point(at: now)
			currentDisplayedGlobalPoint = point
			if anim.isFinished(at: now) {
				animation = nil
			}
		}

		// Cull expired effects.
		clickRings.removeAll { $0.isFinished(at: now) }
		typeFlashes.removeAll { $0.isFinished(at: now) }
		keypressBadges.removeAll { $0.isFinished(at: now) }
		scrollEffects.removeAll { $0.isFinished(at: now) }
		windowPulses.removeAll { $0.isFinished(at: now) }

		// Repaint with whatever cursor + effects are current.
		let pointToRender = currentDisplayedGlobalPoint ?? lastGlobalPoint
		if let pointToRender = pointToRender {
			renderGlobalPoint(pointToRender, now: now)
		} else {
			renderEmpty(now: now)
		}

		// If the cursor's idle fade has fully landed at 0 alpha,
		// also drop the displayed point so the next bumpActivity
		// starts cleanly without a stale anchor. lastGlobalPoint
		// stays - it's the agent's last logical target and the
		// next moveTo may want it as a tween-start anchor.
		if lastActivityTime != nil && currentCursorAlpha(now: now) <= 0.0 {
			currentDisplayedGlobalPoint = nil
			// Clear the activity timestamp so future ticks don't
			// keep doing the fade math forever.
			lastActivityTime = nil
		}

		if animation == nil && !hasActiveEffectsOrFade(now: now) {
			displayTimer?.invalidate()
			displayTimer = nil
		}
	}

/// Paint the cursor at a specific global screen point across all
	/// per-screen overlay windows, plus any active effects projected
	/// into screen-local coords. No state change - callers update
	/// `currentDisplayedGlobalPoint` themselves.
	private func renderGlobalPoint(_ globalPoint: CGPoint, now: CFTimeInterval = CACurrentMediaTime(), forceSynchronousDisplay: Bool = false) {
		// Occlusion check: if the topmost real window under the cursor
		// doesn't belong to the agent's target PID, suppress everything
		// (cursor + effects) so the overlay never appears in front of an
		// app the user has brought to the foreground.
		let shouldRender = shouldRenderForCurrentTarget(at: globalPoint)

		for (index, window) in windows.enumerated() {
			let screen = window.screen ?? NSScreen.screens[index]
			let local = convertGlobalToScreenLocal(globalPoint, screen: screen)
			let view = views[index]
			if !shouldRender {
				view.cursorPoint = nil
				view.clickRings = []
				view.typeFlashes = []
				view.keypressBadges = []
				view.scrollEffects = []
				// Window pulses bypass the cursor-occlusion check:
				// they fire on an explicit window frame (raise / launch /
				// arrange / apple_script-against-app), so the visual
				// honestly represents "agent acted on this window" even
				// when that window is partly or fully occluded by
				// another app. The pulse itself is the localized cue.
				view.windowPulses = windowPulses.map { pulse in
					let rect = convertGlobalRectToScreenLocal(pulse.globalFrame, screen: screen)
					return ScreenLocalWindowPulse(localRect: rect, age: now - pulse.startTime)
				}
				view.needsDisplay = true
				continue
			}
			if NSPointInRect(NSPoint(x: local.x, y: local.y), screen.frame.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)) {
				view.cursorPoint = local
			} else {
				view.cursorPoint = nil
			}
			// Push the current idle-fade alpha so the view draws
			// the cursor at the right opacity this frame.
			view.cursorAlpha = currentCursorAlpha(now: now)
			view.clickRings = clickRings.compactMap { ring in
				let local = convertGlobalToScreenLocal(ring.globalPoint, screen: screen)
				return ScreenLocalClickRing(
					localPoint: local,
					button: ring.button,
					age: now - ring.startTime
				)
			}
			view.typeFlashes = typeFlashes.compactMap { flash in
				let rect: CGRect
				if let g = flash.globalRect {
					rect = convertGlobalRectToScreenLocal(g, screen: screen)
				} else if let p = flash.fallbackCursorPoint {
					let local = convertGlobalToScreenLocal(p, screen: screen)
					rect = CGRect(x: local.x + 14, y: local.y - 14, width: 80, height: 26)
				} else {
					return nil
				}
				return ScreenLocalTypeFlash(localRect: rect, age: now - flash.startTime)
			}
			view.keypressBadges = keypressBadges.map { badge in
				let local = convertGlobalToScreenLocal(badge.globalPoint, screen: screen)
				return ScreenLocalKeypressBadge(localPoint: local, label: badge.label, age: now - badge.startTime)
			}
			view.scrollEffects = scrollEffects.map { effect in
				let local = convertGlobalToScreenLocal(effect.globalPoint, screen: screen)
				return ScreenLocalScrollEffect(localPoint: local, dx: effect.dx, dy: effect.dy, chevronCount: effect.chevronCount, age: now - effect.startTime)
			}
			view.windowPulses = windowPulses.map { pulse in
				let rect = convertGlobalRectToScreenLocal(pulse.globalFrame, screen: screen)
				return ScreenLocalWindowPulse(localRect: rect, age: now - pulse.startTime)
			}
			if forceSynchronousDisplay {
				// Synchronous redraw — used by the drag waypoint path
				// where the main thread is held in a tight usleep loop
				// and the AppKit run loop can't otherwise pump frames.
				// display() repaints the view; the wrapping CATransaction
				// begin/commit forces the layer contents to flush to the
				// WindowServer right now rather than waiting for the
				// next run-loop tick that we're actively blocking.
				CATransaction.begin()
				CATransaction.setDisableActions(true)
				view.display()
				CATransaction.commit()
				CATransaction.flush()
			} else {
				view.needsDisplay = true
			}
		}
	}

	/// Repaint with no cursor (e.g. effects-only state). Lets a
	/// type-flash fire even when we've never tracked a cursor point.
	private func renderEmpty(now: CFTimeInterval) {
		// We pick an arbitrary effect/flash anchor for the occlusion
		// check, since there's no cursor point to test. Click rings vote
		// first; otherwise type-flash bounds; otherwise just render.
		let anchor: CGPoint? = clickRings.first.map { $0.globalPoint }
			?? typeFlashes.compactMap { $0.globalRect.map { CGPoint(x: $0.midX, y: $0.midY) } }.first
			?? keypressBadges.first.map { $0.globalPoint }
			?? scrollEffects.first.map { $0.globalPoint }
			?? windowPulses.first.map { CGPoint(x: $0.globalFrame.midX, y: $0.globalFrame.midY) }
		let shouldRender = anchor.map { shouldRenderForCurrentTarget(at: $0) } ?? true

		for (index, window) in windows.enumerated() {
			let screen = window.screen ?? NSScreen.screens[index]
			let view = views[index]
			view.cursorPoint = nil
			if !shouldRender {
				view.clickRings = []
				view.typeFlashes = []
				view.keypressBadges = []
				view.scrollEffects = []
				// See note in renderGlobalPoint: window pulses honestly
				// announce frame-level agent actions and bypass the
				// cursor-occlusion check.
				view.windowPulses = windowPulses.map { pulse in
					let rect = convertGlobalRectToScreenLocal(pulse.globalFrame, screen: screen)
					return ScreenLocalWindowPulse(localRect: rect, age: now - pulse.startTime)
				}
				view.needsDisplay = true
				continue
			}
			view.clickRings = clickRings.map { ring in
				let local = convertGlobalToScreenLocal(ring.globalPoint, screen: screen)
				return ScreenLocalClickRing(localPoint: local, button: ring.button, age: now - ring.startTime)
			}
			view.typeFlashes = typeFlashes.compactMap { flash in
				guard let g = flash.globalRect else { return nil }
				return ScreenLocalTypeFlash(localRect: convertGlobalRectToScreenLocal(g, screen: screen), age: now - flash.startTime)
			}
			view.keypressBadges = keypressBadges.map { badge in
				let local = convertGlobalToScreenLocal(badge.globalPoint, screen: screen)
				return ScreenLocalKeypressBadge(localPoint: local, label: badge.label, age: now - badge.startTime)
			}
			view.scrollEffects = scrollEffects.map { effect in
				let local = convertGlobalToScreenLocal(effect.globalPoint, screen: screen)
				return ScreenLocalScrollEffect(localPoint: local, dx: effect.dx, dy: effect.dy, chevronCount: effect.chevronCount, age: now - effect.startTime)
			}
			view.windowPulses = windowPulses.map { pulse in
				let rect = convertGlobalRectToScreenLocal(pulse.globalFrame, screen: screen)
				return ScreenLocalWindowPulse(localRect: rect, age: now - pulse.startTime)
			}
			view.needsDisplay = true
		}
	}

	/// Returns true when the overlay should be visible right now: either
	/// occlusion checking is disabled, no target PID has been recorded
	/// (legacy/test callers), or the topmost real window under `point`
	/// belongs to the target PID.
	///
	/// We walk CGWindowListCopyWindowInfo top-down, skip system layers
	/// (`kCGWindowLayer != 0` covers menubar, dock, screen-saver, etc.)
	/// and our own helper's windows (we don't want the overlay to fool
	/// itself into thinking it's the foreground app), and return true
	/// only if the first matching window's owner is the target PID.
	private func shouldRenderForCurrentTarget(at point: CGPoint) -> Bool {
		if !occlusionAware { return true }
		guard let target = lastTargetPid else { return true }
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
			return true
		}
		for entry in entries {
			let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
			if layer != 0 { continue }
			guard let ownerPid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
			if ownerPid == helperPid { continue }
			guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
				let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
			else { continue }
			// CGWindowList bounds are in CG global coords (top-left origin)
			// just like the cursor point we receive. Direct contains() is
			// correct - no AppKit/CG conversion needed here.
			if bounds.contains(point) {
				return ownerPid == target
			}
		}
		// No window covers the point (over the desktop). Treat as visible
		// since the user clearly isn't focused on something else.
		return true
	}

	private func convertGlobalRectToScreenLocal(_ globalCG: CGRect, screen: NSScreen) -> CGRect {
		let topLeft = convertGlobalToScreenLocal(CGPoint(x: globalCG.minX, y: globalCG.minY), screen: screen)
		let bottomRight = convertGlobalToScreenLocal(CGPoint(x: globalCG.maxX, y: globalCG.maxY), screen: screen)
		let x = min(topLeft.x, bottomRight.x)
		let y = min(topLeft.y, bottomRight.y)
		let w = abs(bottomRight.x - topLeft.x)
		let h = abs(bottomRight.y - topLeft.y)
		return CGRect(x: x, y: y, width: w, height: h)
	}

	static func easeOutCubic(_ t: Double) -> Double {
		let inv = 1.0 - t
		return 1.0 - inv * inv * inv
	}

	static func quadraticBezier(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
		let inv = 1.0 - t
		let x = inv * inv * start.x + 2.0 * inv * t * control.x + t * t * end.x
		let y = inv * inv * start.y + 2.0 * inv * t * control.y + t * t * end.y
		return CGPoint(x: x, y: y)
	}

	private func rebuildWindows() {
		for window in windows {
			window.orderOut(nil)
		}
		windows.removeAll()
		views.removeAll()
		for screen in NSScreen.screens {
			let frame = screen.frame
			let window = NSWindow(
				contentRect: frame,
				styleMask: [.borderless],
				backing: .buffered,
				defer: false,
				screen: screen
			)
			window.isOpaque = false
			window.backgroundColor = .clear
			window.hasShadow = false
			window.ignoresMouseEvents = true
			window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
			window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
			window.isReleasedWhenClosed = false
			window.acceptsMouseMovedEvents = false
			window.hidesOnDeactivate = false
			let view = OverlayCursorView(frame: NSRect(origin: .zero, size: frame.size))
			view.wantsLayer = true
			window.contentView = view
			window.orderFrontRegardless()
			windows.append(window)
			views.append(view)
		}
	}

	/// Quartz/CG global coordinates have origin at top-left of the
	/// *primary* screen with y increasing downward. AppKit (NSWindow,
	/// NSScreen) has origin at bottom-left of the primary screen with y
	/// increasing upward. NSWindow content view coordinates are local
	/// to that window's frame in AppKit space, so for a borderless
	/// window matching the screen frame, view-local coords are global
	/// AppKit coords minus the screen's origin.
	private func convertGlobalToScreenLocal(_ globalCG: CGPoint, screen: NSScreen) -> CGPoint {
		let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
		let appKitGlobal = NSPoint(x: globalCG.x, y: primaryHeight - globalCG.y)
		return NSPoint(x: appKitGlobal.x - screen.frame.origin.x, y: appKitGlobal.y - screen.frame.origin.y)
	}
}

final class Bridge {
	private let refStore = AXRefStore()
	private var stdinBuffer = Data()
	private var axEnhancedEnabledPids = Set<Int32>()
	private let stdinQueue = DispatchQueue(label: "pi-computer-use.bridge.stdin")
	private var stdinReadSource: DispatchSourceRead?

	/// Force-populates an app's AX tree by setting `AXEnhancedUserInterface` and
	/// `AXManualAccessibility` on its application element. Many apps — Electron,
	/// Catalyst, web-heavy hybrids — only expose their full AX tree when an
	/// assistive client requests it. Mirrors what VoiceOver and OpenAI's Sky
	/// helper do. Idempotent per process lifetime.
	private func ensureEnhancedAccessibility(pid: Int32) {
		if axEnhancedEnabledPids.contains(pid) { return }
		axEnhancedEnabledPids.insert(pid)
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 1.0)
		_ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
		_ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
	}

	/// Wire stdin into the AppKit run loop. We can't block on
	/// `availableData` from main any more because main has to host
	/// `NSApplication.shared.run()` for overlay windows, animation
	/// timers, and any future AppKit-driven UI. So we read stdin on a
	/// background queue via DispatchSource and marshal each parsed
	/// request onto main for handling.
	func start() {
		let readSource = DispatchSource.makeReadSource(
			fileDescriptor: FileHandle.standardInput.fileDescriptor,
			queue: stdinQueue
		)
		self.stdinReadSource = readSource
		readSource.setEventHandler { [weak self] in
			guard let self = self else { return }
			let available = max(Int(readSource.data), 4096)
			var buffer = Data(count: available)
			let bytesRead: Int = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
				guard let base = rawBuffer.baseAddress else { return -1 }
				return read(FileHandle.standardInput.fileDescriptor, base, available)
			}
			if bytesRead == 0 {
				// EOF on stdin: parent went away, mirror the prior behavior
				// of the blocking-availableData loop and exit cleanly.
				readSource.cancel()
				return
			}
			if bytesRead < 0 {
				// EAGAIN/EINTR or similar; let DispatchSource fire again.
				return
			}
			let slice = buffer.prefix(bytesRead)
			DispatchQueue.main.async {
				self.stdinBuffer.append(slice)
				self.processBufferedInput()
			}
		}
		readSource.setCancelHandler {
			DispatchQueue.main.async { exit(0) }
		}
		readSource.resume()
	}

	private func processBufferedInput() {
		let newline = Data([0x0A])
		while let range = stdinBuffer.range(of: newline) {
			let lineData = stdinBuffer.subdata(in: 0..<range.lowerBound)
			stdinBuffer.removeSubrange(0..<range.upperBound)

			guard !lineData.isEmpty else { continue }
			guard let line = String(data: lineData, encoding: .utf8) else { continue }
			handleLine(line)
		}
	}

	private func handleLine(_ line: String) {
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }

		let fallbackId = "invalid"
		do {
			guard let jsonData = trimmed.data(using: .utf8) else {
				throw BridgeFailure(message: "Input was not valid UTF-8", code: "invalid_request")
			}
			guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
				throw BridgeFailure(message: "Request must be a JSON object", code: "invalid_request")
			}
			let id = (object["id"] as? String) ?? fallbackId

			do {
				let result = try handleRequest(object)
				send([
					"id": id,
					"ok": true,
					"result": result,
				])
			} catch let failure as BridgeFailure {
				send([
					"id": id,
					"ok": false,
					"error": [
						"message": failure.message,
						"code": failure.code,
					],
				])
			} catch {
				send([
					"id": id,
					"ok": false,
					"error": [
						"message": error.localizedDescription,
						"code": "internal_error",
					],
				])
			}
		} catch let failure as BridgeFailure {
			send([
				"id": fallbackId,
				"ok": false,
				"error": [
					"message": failure.message,
					"code": failure.code,
				],
			])
		} catch {
			send([
				"id": fallbackId,
				"ok": false,
				"error": [
					"message": error.localizedDescription,
					"code": "internal_error",
				],
			])
		}
	}

	private func send(_ payload: [String: Any]) {
		guard JSONSerialization.isValidJSONObject(payload),
			let data = try? JSONSerialization.data(withJSONObject: payload),
			let line = String(data: data, encoding: .utf8)
		else {
			return
		}

		if let out = (line + "\n").data(using: .utf8) {
			FileHandle.standardOutput.write(out)
		}
	}

	private func handleRequest(_ request: [String: Any]) throws -> Any {
		let cmd = try stringArg(request, "cmd")

		switch cmd {
		case "checkPermissions":
			return checkPermissions()
		case "openPermissionPane":
			return try openPermissionPane(request)
		case "listApps":
			return listApps()
		case "listWindows":
			return try listWindows(pid: Int32(try intArg(request, "pid")))
		case "wakeWindow":
			return try wakeWindow(request)
		case "surfaceWindow":
			return try surfaceWindow(request)
		case "launchApp":
			return try launchApp(request)
		case "pulseAppWindow":
			return try pulseAppWindow(request)
		case "getFrontmost":
			return try getFrontmost()
		case "getUserContext":
			return try getUserContext()
		case "setWindowFrame":
			return try setWindowFrame(request)
		case "screenshot":
			return try screenshot(request)
		case "mouseClick":
			return try mouseClick(request)
		case "mouseMove":
			return try mouseMove(request)
		case "mouseDrag":
			return try mouseDrag(request)
		case "scrollWheel":
			return try scrollWheel(request)
		case "keyPress":
			return try keyPress(request)
		case "axPressAtPoint":
			return try axPressAtPoint(request)
		case "axFindTextInput":
			return try axFindTextInput(request)
		case "axFocusTextInput":
			return try axFocusTextInput(request)
		case "axListTargets":
			return try axListTargets(request)
		case "axPressElement":
			return try axPressElement(request)
		case "axPerformActionElement":
			return try axPerformActionElement(request)
		case "axFocusElement":
			return try axFocusElement(request)
		case "axFocusAtPoint":
			return try axFocusAtPoint(request)
		case "axScrollElement":
			return try axScrollElement(request)
		case "axScrollAtPoint":
			return try axScrollAtPoint(request)
		case "focusedElement":
			return try focusedElement(request)
		case "setValue":
			return try setValue(request)
		case "typeText":
			return try typeText(request)
		case "getMousePosition":
			return getMousePosition()
		case "overlayEnable":
			OverlayController.shared.enable()
			return ["enabled": OverlayController.shared.isEnabled()]
		case "overlayDisable":
			OverlayController.shared.disable()
			return ["enabled": OverlayController.shared.isEnabled()]
		case "overlayMoveTo":
			let x = try doubleArg(request, "x")
			let y = try doubleArg(request, "y")
			let pid = optionalIntArg(request, "pid").map { pid_t($0) }
			OverlayController.shared.moveTo(globalPoint: CGPoint(x: x, y: y), ownerPid: pid)
			return ["moved": OverlayController.shared.isEnabled()]
		case "overlayClickEffect":
			let x = try doubleArg(request, "x")
			let y = try doubleArg(request, "y")
			let button = CursorEffectButton(rawValue: optionalStringArg(request, "button")?.lowercased() ?? "left") ?? .left
			let count = optionalIntArg(request, "count") ?? 1
			let pid = optionalIntArg(request, "pid").map { pid_t($0) }
			OverlayController.shared.triggerClickRing(globalPoint: CGPoint(x: x, y: y), button: button, count: count, ownerPid: pid)
			return ["triggered": OverlayController.shared.isEnabled()]
		case "overlayTypeEffect":
			let x = try? doubleArg(request, "x")
			let y = try? doubleArg(request, "y")
			let w = try? doubleArg(request, "w")
			let h = try? doubleArg(request, "h")
			let pid = optionalIntArg(request, "pid").map { pid_t($0) }
			var rect: CGRect? = nil
			if let x = x, let y = y, let w = w, let h = h, w > 0, h > 0 {
				rect = CGRect(x: x, y: y, width: w, height: h)
			}
			OverlayController.shared.triggerTypeFlash(globalRect: rect, ownerPid: pid)
			return ["triggered": OverlayController.shared.isEnabled()]
		case "overlayKeypressEffect":
			let label = try stringArg(request, "label")
			let x = try? doubleArg(request, "x")
			let y = try? doubleArg(request, "y")
			let pid = optionalIntArg(request, "pid").map { pid_t($0) }
			var point: CGPoint? = nil
			if let x = x, let y = y {
				point = CGPoint(x: x, y: y)
			}
			OverlayController.shared.triggerKeypressBadge(label: label, globalPoint: point, ownerPid: pid)
			return ["triggered": OverlayController.shared.isEnabled()]
		case "overlayScrollEffect":
			let x = try doubleArg(request, "x")
			let y = try doubleArg(request, "y")
			let dx = optionalIntArg(request, "deltaX") ?? 0
			let dy = optionalIntArg(request, "deltaY") ?? 0
			let pid = optionalIntArg(request, "pid").map { pid_t($0) }
			OverlayController.shared.triggerScrollEffect(globalPoint: CGPoint(x: x, y: y), deltaX: dx, deltaY: dy, ownerPid: pid)
			return ["triggered": OverlayController.shared.isEnabled()]
		case "overlayWindowPulse":
			let x = try doubleArg(request, "x")
			let y = try doubleArg(request, "y")
			let width = try doubleArg(request, "width")
			let height = try doubleArg(request, "height")
			let pid = optionalIntArg(request, "pid").map { pid_t($0) }
			OverlayController.shared.triggerWindowPulse(globalFrame: CGRect(x: x, y: y, width: width, height: height), ownerPid: pid)
			return ["triggered": OverlayController.shared.isEnabled()]
		case "overlayConfigure":
			if let style = optionalStringArg(request, "style") {
				OverlayController.shared.animationStyle = OverlayAnimationStyle(style)
			}
			if let durationMs = (request["durationMs"] as? NSNumber)?.doubleValue, durationMs >= 0 {
				OverlayController.shared.animationDuration = max(0.0, durationMs / 1000.0)
			}
			if let occlusion = (request["occlusionAware"] as? NSNumber)?.boolValue {
				OverlayController.shared.occlusionAware = occlusion
			}
			return [
				"style": OverlayController.shared.animationStyle.rawValue,
				"durationMs": Int(OverlayController.shared.animationDuration * 1000),
				"occlusionAware": OverlayController.shared.occlusionAware,
			]
		default:
			throw BridgeFailure(message: "Unknown command '\(cmd)'", code: "unknown_command")
		}
	}

	private func stringArg(_ request: [String: Any], _ key: String) throws -> String {
		if let value = request[key] as? String {
			return value
		}
		throw BridgeFailure(message: "Missing string argument '\(key)'", code: "invalid_args")
	}

	private func optionalStringArg(_ request: [String: Any], _ key: String) -> String? {
		if let value = request[key] as? String {
			return value
		}
		return nil
	}

	private func intArg(_ request: [String: Any], _ key: String) throws -> Int {
		if let value = request[key] as? Int {
			return value
		}
		if let value = request[key] as? NSNumber {
			return value.intValue
		}
		if let value = request[key] as? Double {
			return Int(value)
		}
		throw BridgeFailure(message: "Missing integer argument '\(key)'", code: "invalid_args")
	}

	private func optionalIntArg(_ request: [String: Any], _ key: String) -> Int? {
		if let value = request[key] as? Int {
			return value
		}
		if let value = request[key] as? NSNumber {
			return value.intValue
		}
		if let value = request[key] as? Double {
			return Int(value)
		}
		return nil
	}

	private func doubleArg(_ request: [String: Any], _ key: String) throws -> Double {
		if let value = request[key] as? Double {
			return value
		}
		if let value = request[key] as? NSNumber {
			return value.doubleValue
		}
		if let value = request[key] as? Int {
			return Double(value)
		}
		throw BridgeFailure(message: "Missing numeric argument '\(key)'", code: "invalid_args")
	}

	private func checkPermissions() -> [String: Any] {
		let accessibility = AXIsProcessTrusted()
		let screenRecording: Bool
		if #available(macOS 10.15, *) {
			screenRecording = CGPreflightScreenCaptureAccess()
		} else {
			screenRecording = true
		}
		return [
			"accessibility": accessibility,
			"screenRecording": screenRecording,
		]
	}

	private func openPermissionPane(_ request: [String: Any]) throws -> [String: Any] {
		let kind = try stringArg(request, "kind")
		let urlString: String
		var requested = false
		switch kind {
		case "accessibility":
			let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
			_ = AXIsProcessTrustedWithOptions(options)
			requested = true
			urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
		case "screenRecording", "screenrecording":
			if #available(macOS 10.15, *) {
				_ = CGRequestScreenCaptureAccess()
				requested = true
			}
			urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
		default:
			throw BridgeFailure(message: "Unknown permission pane '\(kind)'", code: "invalid_args")
		}

		guard let url = URL(string: urlString) else {
			throw BridgeFailure(message: "Invalid permission pane URL", code: "internal_error")
		}
		let opened = NSWorkspace.shared.open(url)
		return ["opened": opened, "requested": requested]
	}

	private func listApps() -> [[String: Any]] {
		let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
		let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
		return apps.map { app in
			var data: [String: Any] = [
				"appName": app.localizedName ?? "Unknown App",
				"pid": Int(app.processIdentifier),
				"isFrontmost": app.processIdentifier == frontmostPid,
			]
			if let bundleId = app.bundleIdentifier {
				data["bundleId"] = bundleId
			}
			return data
		}
	}

	private func getFrontmost() throws -> [String: Any] {
		guard let app = NSWorkspace.shared.frontmostApplication else {
			throw BridgeFailure(message: "No frontmost app available", code: "frontmost_unavailable")
		}
		let pid = app.processIdentifier
		let windows = try listWindows(pid: pid)

		var result: [String: Any] = [
			"appName": app.localizedName ?? "Unknown App",
			"pid": Int(pid),
		]
		if let bundleId = app.bundleIdentifier {
			result["bundleId"] = bundleId
		}

		if let chosen = windows.sorted(by: { scoreWindow($0) > scoreWindow($1) }).first {
			result["windowTitle"] = (chosen["title"] as? String) ?? ""
			if let windowId = chosen["windowId"] {
				result["windowId"] = windowId
			}
			if let windowRef = chosen["windowRef"] as? String {
				result["windowRef"] = windowRef
			}
		}
		return result
	}

	private func getUserContext() throws -> [String: Any] {
		guard let app = NSWorkspace.shared.frontmostApplication else {
			throw BridgeFailure(message: "No frontmost app available", code: "frontmost_unavailable")
		}
		ensureEnhancedAccessibility(pid: app.processIdentifier)
		let pid = app.processIdentifier
		let appElement = AXUIElementCreateApplication(pid)
		let focusedWindow = copyAttribute(appElement, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement)
		let focusedElement = copyAttribute(appElement, attribute: kAXFocusedUIElementAttribute as CFString).flatMap(asAXElement)
		var result: [String: Any] = [
			"appName": app.localizedName ?? "Unknown App",
			"pid": Int(pid),
		]
		if let bundleId = app.bundleIdentifier {
			result["bundleId"] = bundleId
		}
		if let window = focusedWindow {
			result["window"] = [
				"title": stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "",
				"role": stringAttribute(window, attribute: kAXRoleAttribute as CFString) ?? "",
				"subrole": stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? "",
			]
		}
		if let element = focusedElement {
			result["focusedElement"] = [
				"role": stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? "",
				"subrole": stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? "",
				"title": stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "",
				"description": stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? "",
				"value": stringAttribute(element, attribute: kAXValueAttribute as CFString) ?? "",
			]
		}
		return result
	}

	private func setWindowFrame(_ request: [String: Any]) throws -> [String: Any] {
		let pid = Int32(try intArg(request, "pid"))
		let windowId = optionalIntArg(request, "windowId").map { UInt32($0) }
		let windowRef = optionalStringArg(request, "windowRef")
		guard let window = windowElement(pid: pid, windowId: windowId, windowRef: windowRef) else {
			return ["ok": false, "reason": "window_not_found"]
		}
		let x = try doubleArg(request, "x")
		let y = try doubleArg(request, "y")
		let width = max(100.0, try doubleArg(request, "width"))
		let height = max(80.0, try doubleArg(request, "height"))
		var origin = CGPoint(x: x, y: y)
		var size = CGSize(width: width, height: height)
		guard let originValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else {
			throw BridgeFailure(message: "Failed to create AX frame values", code: "frame_value_failed")
		}
		let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
		let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
		let frame = frameForWindow(window)
		// Slice 21: amber pulse around the new window frame so an
		// arrange_window action ties the visible move/resize to the
		// agent's intent. Only fire if at least one AX setter succeeded
		// (so a "failed both" call doesn't paint a misleading cue).
		if (positionStatus == .success || sizeStatus == .success) && frame.width > 0 && frame.height > 0 {
			OverlayController.shared.triggerWindowPulse(globalFrame: frame, ownerPid: pid)
		}
		return [
			"ok": positionStatus == .success || sizeStatus == .success,
			"positionStatus": Int(positionStatus.rawValue),
			"sizeStatus": Int(sizeStatus.rawValue),
			"framePoints": ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height],
		]
	}

	private func scoreWindow(_ window: [String: Any]) -> Int {
		var score = 0
		if (window["isFocused"] as? Bool) == true { score += 100 }
		if (window["isMain"] as? Bool) == true { score += 80 }
		if (window["isMinimized"] as? Bool) == false { score += 40 }
		if (window["isOnscreen"] as? Bool) == true { score += 20 }
		if window["windowId"] != nil { score += 10 }
		return score
	}

	private func listWindows(pid: Int32) throws -> [[String: Any]] {
		ensureEnhancedAccessibility(pid: pid)
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 1.0)
		let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
		let candidates = cgWindowCandidates(pid: pid)
		var usedIds = Set<UInt32>()

		// CGWindowList entries we'll use to synthesize "window exists but
		// has no AX presence" entries after the AX walk. Off-Space windows
		// generally don't appear in kAXWindowsAttribute at all, so we fill
		// them in from CGWindowList so the agent can still see + wake them.
		let candidatesByWindowId: [UInt32: CGWindowCandidate] = candidates.reduce(into: [:]) { acc, c in
			acc[c.windowId] = c
		}

		var output: [[String: Any]] = []
		for window in windows {
			let axTitle = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
			let axFrame = frameForWindow(window)
			let candidate = bestCandidate(frame: axFrame, title: axTitle, candidates: candidates, usedIds: usedIds)
			if let candidate {
				usedIds.insert(candidate.windowId)
			}

			let hasUsableAXFrame = axFrame.width > 1 && axFrame.height > 1
			let effectiveFrame = hasUsableAXFrame ? axFrame : (candidate?.bounds ?? axFrame)

			// Off-Space windows often have a zeroed AX frame because the
			// window isn't being rendered, but they still appear in
			// CGWindowList with their last-known bounds. Don't drop them on
			// the size filter just because AX is being unhelpful - the agent
			// can still drive them via AX actions, and the windowId lets us
			// `wake_window` them back to the active Space when needed.
			let axIsOffSpace = !hasUsableAXFrame && candidate != nil && !(candidate!.isOnscreen)
			if !axIsOffSpace {
				if effectiveFrame.width < 100 || effectiveFrame.height < 80 { continue }
			}

			let title = hasUsableAXFrame && !axTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? axTitle : (candidate?.title.isEmpty == false ? candidate!.title : axTitle)
			let windowRef = refStore.storeWindow(window)
			let isMinimized = boolAttribute(window, attribute: kAXMinimizedAttribute as CFString) ?? false
			let isMain = boolAttribute(window, attribute: kAXMainAttribute as CFString) ?? false
			let isFocused = boolAttribute(window, attribute: kAXFocusedAttribute as CFString) ?? false
			let scale = displayScaleFactor(for: effectiveFrame)
			let isOnscreen = candidate?.isOnscreen ?? !isMinimized
			// Active Space heuristic: if the window is unminimized but
			// CGWindowList says it's not on-screen, it's almost certainly
			// on another Space. Minimized windows are a separate case the
			// caller can detect via isMinimized.
			let isOnActiveSpace = isMinimized || isOnscreen

			var item: [String: Any] = [
				"windowRef": windowRef,
				"title": title,
				"framePoints": [
					"x": effectiveFrame.origin.x,
					"y": effectiveFrame.origin.y,
					"w": effectiveFrame.size.width,
					"h": effectiveFrame.size.height,
				],
				"scaleFactor": scale,
				"isMinimized": isMinimized,
				"isOnscreen": isOnscreen,
				"isOnActiveSpace": isOnActiveSpace,
				"isMain": isMain,
				"isFocused": isFocused,
			]
			if let candidate {
				item["windowId"] = Int(candidate.windowId)
			}
			output.append(item)
		}

		// Synthesize entries for CGWindowList windows that AX never
		// surfaced. These are almost always off-Space windows: AX returns
		// an empty kAXWindowsAttribute for them, but they remain fully
		// addressable via CGWindowList and can be woken with wake_window.
		// We mark them isOnActiveSpace=false so the agent knows to raise
		// them before targeting; they have no windowRef because there's no
		// live AX element to back one.
		for (windowId, candidate) in candidatesByWindowId where !usedIds.contains(windowId) {
			let bounds = candidate.bounds
			// Apply the same minimum-size filter as for AX windows so we
			// don't surface every transient HUD/palette as a controllable
			// target; off-Space windows of real apps still pass this since
			// CGWindowList preserves their last on-screen size.
			if bounds.width < 100 || bounds.height < 80 { continue }
			let title = candidate.title
			// Without an AX element we can't tell a real window from a
			// detached toolbar/sheet. Require a non-empty title to filter
			// the chrome out; real off-Space windows almost always retain
			// their title in CGWindowList.
			if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
			var item: [String: Any] = [
				"title": title,
				"framePoints": [
					"x": bounds.origin.x,
					"y": bounds.origin.y,
					"w": bounds.size.width,
					"h": bounds.size.height,
				],
				"scaleFactor": displayScaleFactor(for: bounds),
				"isMinimized": false,
				"isOnscreen": candidate.isOnscreen,
				"isOnActiveSpace": candidate.isOnscreen,
				"isMain": false,
				"isFocused": false,
				"windowId": Int(windowId),
			]
			output.append(item)
		}
		return output
	}

	/// Bring a window to the active Space and raise it without changing
	/// the user's frontmost app. We use NSRunningApplication's activate
	/// without options for a polite raise, then AXRaiseAction on the
	/// window itself which is what asks the WindowServer to drag the
	/// window onto the current Space. Per-PID delivery, so the raise
	/// doesn't ripple through to other apps.
	/// wakeWindow is a STATUS + RECOVERY tool, not a window-mover.
	///
	/// macOS does not let one process silently move another process's
	/// window between Spaces (SLSMoveWindowsToManagedSpace returns CGS
	/// permission denied without a SIP-disabled scripting addition
	/// injected into Dock.app). The only honest cross-Space recovery
	/// paths are:
	///
	/// 1. Un-minimize a minimized window via AX. Quiet, in-contract.
	/// 2. Drive the app via non-GUI paths (apple_script, URL schemes,
	///    file edits, native command-line tooling) so the off-Space
	///    window doesn't need to be surfaced at all.
	/// 3. Ask the user to swipe to the window's Space themselves.
	/// 4. Call surfaceWindow as a last resort - that's the explicit,
	///    user-permission-required disruptive action.
	///
	/// wakeWindow returns a structured "here are your alternatives"
	/// payload. It NEVER calls NSRunningApplication.activate() or
	/// AXRaiseAction. The agent uses the response to plan its next
	/// move; the TS layer enriches the payload with bundled-instruction
	/// detection and apple_script availability.
	private func wakeWindow(_ request: [String: Any]) throws -> [String: Any] {
		let windowRef = optionalStringArg(request, "windowRef")
		let windowIdArg = optionalIntArg(request, "windowId").map { UInt32($0) }
		let pidArg = optionalIntArg(request, "pid").map { Int32($0) }

		let (axWindow, resolvedPid, resolvedWindowId) = try resolveWakeTarget(
			windowRef: windowRef,
			windowIdArg: windowIdArg,
			pidArg: pidArg
		)

		guard let pid = resolvedPid else {
			throw BridgeFailure(message: "wakeWindow requires either a windowRef or both windowId and pid", code: "invalid_args")
		}

		var result: [String: Any] = [
			"pid": Int(pid),
			"action": "status",
			"unminimized": false,
		]
		if let resolvedWindowId {
			result["windowId"] = Int(resolvedWindowId)
		}

		// Detect on/off Space by AX visibility. If the AX element walk
		// returned a window we can reach, the window is on the active
		// Space (or minimized but reachable on it). If we had to fall
		// back to the synthesized CGWindowList path (no axWindow but a
		// resolvedWindowId from the request), the window is off-Space.
		let isOffActiveSpace: Bool = (axWindow == nil)
		let isMinimized: Bool = axWindow.flatMap { boolAttribute($0, attribute: kAXMinimizedAttribute as CFString) } ?? false
		result["isOffActiveSpace"] = isOffActiveSpace
		result["isMinimized"] = isMinimized

		// Quiet recovery path: a minimized window can be un-minimized via
		// AX without changing Spaces or stealing focus. This is the only
		// recovery this tool will perform on its own.
		if let axWindow, isMinimized {
			let status = AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
			if status == .success {
				result["unminimized"] = true
				result["action"] = "unminimized"
				return result
			}
		}

		if isOffActiveSpace {
			result["action"] = "off_space_status"
		} else {
			result["action"] = "on_space_status"
		}
		return result
	}

	/// surfaceWindow is the EXPLICIT disruptive recovery: it activates
	/// the app and raises the window. On macOS this also switches the
	/// user's viewport to the window's Space (or moves the window onto
	/// the active Space, depending on the user's Spaces settings).
	///
	/// The TS layer enforces "agent must ask user permission first";
	/// this command is just the mechanism. Returns whether activate +
	/// AXRaise succeeded so the agent can confirm before the next call.
	private func surfaceWindow(_ request: [String: Any]) throws -> [String: Any] {
		let windowRef = optionalStringArg(request, "windowRef")
		let windowIdArg = optionalIntArg(request, "windowId").map { UInt32($0) }
		let pidArg = optionalIntArg(request, "pid").map { Int32($0) }

		let (axWindow, resolvedPid, resolvedWindowId) = try resolveWakeTarget(
			windowRef: windowRef,
			windowIdArg: windowIdArg,
			pidArg: pidArg
		)

		guard let pid = resolvedPid else {
			throw BridgeFailure(message: "surfaceWindow requires either a windowRef or both windowId and pid", code: "invalid_args")
		}

		var appActivated = false
		if let runningApp = NSRunningApplication(processIdentifier: pid) {
			appActivated = runningApp.activate(options: [])
		}

		var windowRaised = false
		if let axWindow {
			let status = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
			windowRaised = (status == .success)
		}

		// Settle loop: after activate + AXRaise, the window-server takes a
		// few hundred ms to commit the new on-screen state to CGWindowList
		// and SCK. Without this, an immediate follow-up screenshot races
		// the transition: CGWindowList still reports kCGWindowIsOnscreen=
		// false, my new off-Space gate over-rejects, and SCK's
		// captureImage hangs indefinitely (well past pi's 25s timeout).
		// Poll every 50ms up to 2s for CGWindowList to agree the window is
		// onscreen. Cheap when transition is fast; bounded when it isn't.
		var settled = false
		if let resolvedWindowId {
			for _ in 0..<40 {
				if let onscreen = isWindowOnscreen(windowId: resolvedWindowId), onscreen {
					settled = true
					break
				}
				Thread.sleep(forTimeInterval: 0.05)
			}
		}

		// Slice 21: amber pulse around the surfaced window's frame so
		// the user sees a visible "target acquired" tie-in to the
		// agent's surface_window call (which they just approved via
		// ctx.ui.confirm). Fire AFTER the settle loop so the window is
		// actually onscreen on the active Space when the pulse paints,
		// not mid-transition. Re-read the AX frame post-settle in case
		// the Space switch reflowed the window (some apps revalidate).
		if let axWindow, appActivated || windowRaised {
			let frame = frameForWindow(axWindow)
			if frame.width > 0 && frame.height > 0 {
				OverlayController.shared.triggerWindowPulse(globalFrame: frame, ownerPid: pid)
			}
		}

		var result: [String: Any] = [
			"pid": Int(pid),
			"appActivated": appActivated,
			"windowRaised": windowRaised,
			"settled": settled,
		]
		if let resolvedWindowId {
			result["windowId"] = Int(resolvedWindowId)
		}
		return result
	}

	/// Launch an app, optionally without stealing focus. Stealth model v2
	/// allows the agent to launch background-runnable apps freely; if it
	/// wants the app foreground, it should ask the user first via the
	/// permission gate enforced by the TS layer.
	///
	/// Looks up the app by bundleId first, then by appName. Uses
	/// NSWorkspace.openApplication(at:configuration:) with activates set
	/// per the request. Returns the launched (or already-running) pid so
	/// the agent can immediately call screenshot/list_windows/etc.
	private func launchApp(_ request: [String: Any]) throws -> [String: Any] {
		let bundleId = optionalStringArg(request, "bundleId")
		let appName = optionalStringArg(request, "appName")
		let activate = (request["activate"] as? NSNumber)?.boolValue ?? false

		var appURL: URL? = nil
		if let bundleId, !bundleId.isEmpty {
			appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
		}
		if appURL == nil, let appName, !appName.isEmpty {
			if let path = NSWorkspace.shared.fullPath(forApplication: appName) {
				appURL = URL(fileURLWithPath: path)
			}
		}
		guard let appURL else {
			throw BridgeFailure(
				message: "launchApp could not resolve an app to launch. Provide bundleId (e.g. 'com.apple.TextEdit') or appName (e.g. 'TextEdit'); both must match an installed app.",
				code: "app_not_found"
			)
		}

		let resolvedBundleId = Bundle(url: appURL)?.bundleIdentifier ?? bundleId

		// If the app is already running, short-circuit and return the
		// existing pid. Honors the activate flag: if the caller asked
		// to activate and the app is already running, we still raise it.
		let running = NSRunningApplication.runningApplications(withBundleIdentifier: resolvedBundleId ?? "")
		if let existing = running.first {
			var didActivate = false
			if activate {
				didActivate = existing.activate(options: [])
			}
			// Slice 21: amber pulse around the activated app's main
			// window so the foreground takeover ties to the agent's
			// launch_app({activate:true}) intent. Skip when activate=
			// false: a background launch produces no visible window
			// state change so the pulse would be misleading.
			if didActivate, let frame = primaryWindowFrame(forPid: existing.processIdentifier) {
				OverlayController.shared.triggerWindowPulse(globalFrame: frame, ownerPid: existing.processIdentifier)
			}
			return [
				"pid": Int(existing.processIdentifier),
				"appName": existing.localizedName ?? appName ?? appURL.lastPathComponent,
				"bundleId": existing.bundleIdentifier ?? "",
				"alreadyRunning": true,
				"activated": didActivate,
			]
		}

		let config = NSWorkspace.OpenConfiguration()
		config.activates = activate
		config.addsToRecentItems = false

		let sema = DispatchSemaphore(value: 0)
		var launchedApp: NSRunningApplication? = nil
		var launchError: Error? = nil
		NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
			launchedApp = app
			launchError = error
			sema.signal()
		}
		// 10s budget for launches; matches the helper's COMMAND_TIMEOUT_MS
		// behavior on the TS side. NSWorkspace.openApplication can stall
		// briefly during cold launches but a hung app should fail loudly.
		let waitResult = sema.wait(timeout: .now() + .seconds(10))
		if waitResult == .timedOut {
			throw BridgeFailure(message: "launchApp timed out waiting for the app to launch.", code: "launch_timeout")
		}
		if let launchError {
			throw BridgeFailure(message: "launchApp failed: \(launchError.localizedDescription)", code: "launch_failed")
		}
		guard let launchedApp else {
			throw BridgeFailure(message: "launchApp returned no NSRunningApplication.", code: "launch_failed")
		}

		// Slice 21: amber pulse around the launched app's main window
		// so a foreground launch ties to the agent's intent. Fresh
		// launches need a brief settle before AX exposes the window;
		// poll up to 1.5s for a usable frame, then pulse. Skip when
		// activate=false (background launch produces no visible window
		// state change worth pulsing).
		if activate {
			var pulseFrame: CGRect? = nil
			for _ in 0..<30 {
				if let frame = primaryWindowFrame(forPid: launchedApp.processIdentifier) {
					pulseFrame = frame
					break
				}
				Thread.sleep(forTimeInterval: 0.05)
			}
			if let pulseFrame {
				OverlayController.shared.triggerWindowPulse(globalFrame: pulseFrame, ownerPid: launchedApp.processIdentifier)
			}
		}

		return [
			"pid": Int(launchedApp.processIdentifier),
			"appName": launchedApp.localizedName ?? appName ?? appURL.lastPathComponent,
			"bundleId": launchedApp.bundleIdentifier ?? "",
			"alreadyRunning": false,
			"activated": activate,
		]
	}

	/// Best-effort "give me the main window's frame" probe for a pid.
	/// Used by launchApp's slice-21 pulse: returns the AX-reported
	/// frame of whichever window is marked main / focused / first,
	/// or nil if the app has no AX-visible windows yet (common during
	/// the first ~500ms of a cold launch).
	private func primaryWindowFrame(forPid pid: pid_t) -> CGRect? {
		ensureEnhancedAccessibility(pid: pid)
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 1.0)
		let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
		if windows.isEmpty { return nil }
		for window in windows {
			if boolAttribute(window, attribute: kAXMainAttribute as CFString) == true {
				let frame = frameForWindow(window)
				if frame.width > 0 && frame.height > 0 { return frame }
			}
		}
		for window in windows {
			if boolAttribute(window, attribute: kAXFocusedAttribute as CFString) == true {
				let frame = frameForWindow(window)
				if frame.width > 0 && frame.height > 0 { return frame }
			}
		}
		let frame = frameForWindow(windows[0])
		return (frame.width > 0 && frame.height > 0) ? frame : nil
	}

	/// Slice 22: resolve an app (by `app` display name or `bundleId`)
	/// and fire the amber window pulse around its primary window's
	/// frame so an `apple_script` invocation against that app ties
	/// visibly to the agent's intent. AppleScript runs entirely in
	/// the host pi process via `osascript` and the bridge has no idea
	/// what it's doing internally; this gives the user a "hey, an
	/// AppleScript ran against this app" visual without us needing
	/// to parse or sandbox the script.
	///
	/// Returns a status payload so the TS caller can log whether the
	/// pulse actually fired (app not running, no AX-visible window,
	/// or pulse dropped for zero-area frame all return
	/// `triggered: false` with a reason).
	private func pulseAppWindow(_ request: [String: Any]) throws -> [String: Any] {
		let bundleId = optionalStringArg(request, "bundleId")
		let appName = optionalStringArg(request, "app")

		var running: NSRunningApplication? = nil
		if let bundleId, !bundleId.isEmpty {
			running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
		}
		if running == nil, let appName, !appName.isEmpty {
			let lower = appName.lowercased()
			running = NSWorkspace.shared.runningApplications.first { app in
				guard let localized = app.localizedName?.lowercased() else { return false }
				return localized == lower
			}
		}
		guard let running else {
			return ["triggered": false, "reason": "app_not_running"]
		}

		guard let frame = primaryWindowFrame(forPid: running.processIdentifier) else {
			// Common cases: agent ran an AppleScript against an app with
			// no visible window (background daemon, just-launched app,
			// menu-bar-only utility). Honest no-op — we don't paint a
			// cue for an invisible target.
			return [
				"triggered": false,
				"reason": "no_visible_window",
				"pid": Int(running.processIdentifier),
			]
		}

		OverlayController.shared.triggerWindowPulse(globalFrame: frame, ownerPid: running.processIdentifier)
		return [
			"triggered": OverlayController.shared.isEnabled(),
			"pid": Int(running.processIdentifier),
			"framePoints": ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height],
		]
	}

	/// Shared resolver for wakeWindow / surfaceWindow. Returns the
	/// optional AX element (nil for synthesized off-Space entries), the
	/// resolved pid, and the resolved CGWindowID.
	private func resolveWakeTarget(
		windowRef: String?,
		windowIdArg: UInt32?,
		pidArg: Int32?
	) throws -> (axWindow: AXUIElement?, pid: Int32?, windowId: UInt32?) {
		var axWindow: AXUIElement? = nil
		var targetPid: Int32? = pidArg
		var resolvedWindowId: UInt32? = windowIdArg

		if let windowRef, let element = refStore.window(for: windowRef) {
			axWindow = element
			var pidOut: pid_t = 0
			if AXUIElementGetPid(element, &pidOut) == .success, pidOut > 0 {
				targetPid = pidOut
			}
		}

		if resolvedWindowId == nil, let pid = targetPid, let element = axWindow {
			// Match the AX element to a CGWindowList candidate to recover
			// its windowId. Same pattern listWindows uses.
			let candidates = cgWindowCandidates(pid: pid)
			let axTitle = stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
			let axFrame = frameForWindow(element)
			if let candidate = bestCandidate(frame: axFrame, title: axTitle, candidates: candidates, usedIds: Set<UInt32>()) {
				resolvedWindowId = candidate.windowId
			}
		}

		if axWindow == nil, let windowId = resolvedWindowId, let pid = targetPid {
			// Try to recover an AX ref so we can attempt the unminimize
			// path. Walk the app's AX windows and match by windowId.
			let appElement = AXUIElementCreateApplication(pid)
			AXUIElementSetMessagingTimeout(appElement, 1.0)
			let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
			let candidates = cgWindowCandidates(pid: pid)
			var usedIds = Set<UInt32>()
			for window in windows {
				let axTitle = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
				let axFrame = frameForWindow(window)
				let candidate = bestCandidate(frame: axFrame, title: axTitle, candidates: candidates, usedIds: usedIds)
				if let candidate { usedIds.insert(candidate.windowId) }
				if candidate?.windowId == windowId {
					axWindow = window
					break
				}
			}
		}

		return (axWindow, targetPid, resolvedWindowId)
	}

	private func screenshot(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		return try captureWindow(windowId: windowId)
	}

	private func mouseClick(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		let x = try doubleArg(request, "x")
		let y = try doubleArg(request, "y")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "mouseClick requires pid in non-intrusive mode", code: "pid_required")
		}
		let captureWidth = max(1.0, (try? doubleArg(request, "captureWidth")) ?? 1.0)
		let captureHeight = max(1.0, (try? doubleArg(request, "captureHeight")) ?? 1.0)
		let button = mouseButton(optionalStringArg(request, "button") ?? "left")
		let clickCount = max(1, min(3, optionalIntArg(request, "clickCount") ?? 1))
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight, windowFrame: windowFrameArg(request))
		ensureFrontmostForOpaqueFramebuffer(pid: targetPid, windowId: windowId)
		try postMouseClick(at: point, pid: targetPid, button: button, clickCount: clickCount)
		return ["clicked": true]
	}

	private func mouseMove(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		let x = try doubleArg(request, "x")
		let y = try doubleArg(request, "y")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "mouseMove requires pid in non-intrusive mode", code: "pid_required")
		}
		let captureWidth = max(1.0, (try? doubleArg(request, "captureWidth")) ?? 1.0)
		let captureHeight = max(1.0, (try? doubleArg(request, "captureHeight")) ?? 1.0)
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight, windowFrame: windowFrameArg(request))
		ensureFrontmostForOpaqueFramebuffer(pid: targetPid, windowId: windowId)
		try postMouseMove(to: point, pid: targetPid)
		return ["moved": true]
	}

	private func mouseDrag(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "mouseDrag requires pid in non-intrusive mode", code: "pid_required")
		}
		guard let rawPath = request["path"] as? [[String: Any]], rawPath.count >= 2 else {
			throw BridgeFailure(message: "mouseDrag requires a path with at least two points", code: "invalid_args")
		}
		let captureWidth = max(1.0, (try? doubleArg(request, "captureWidth")) ?? 1.0)
		let captureHeight = max(1.0, (try? doubleArg(request, "captureHeight")) ?? 1.0)
		let frame = windowFrameArg(request)
		let points = try rawPath.map { rawPoint -> CGPoint in
			guard let x = (rawPoint["x"] as? NSNumber)?.doubleValue,
				let y = (rawPoint["y"] as? NSNumber)?.doubleValue
			else {
				throw BridgeFailure(message: "mouseDrag path entries must include numeric x and y", code: "invalid_args")
			}
			return try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight, windowFrame: frame)
		}
		ensureFrontmostForOpaqueFramebuffer(pid: targetPid, windowId: windowId)
		try postMouseDrag(points: points, pid: targetPid)
		return ["dragged": true]
	}

	private func scrollWheel(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		let x = try doubleArg(request, "x")
		let y = try doubleArg(request, "y")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "scrollWheel requires pid in non-intrusive mode", code: "pid_required")
		}
		let captureWidth = max(1.0, (try? doubleArg(request, "captureWidth")) ?? 1.0)
		let captureHeight = max(1.0, (try? doubleArg(request, "captureHeight")) ?? 1.0)
		let scrollX = optionalIntArg(request, "scrollX") ?? 0
		let scrollY = optionalIntArg(request, "scrollY") ?? 0
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight, windowFrame: windowFrameArg(request))
		ensureFrontmostForOpaqueFramebuffer(pid: targetPid, windowId: windowId)
		try postScrollWheel(at: point, deltaX: scrollX, deltaY: scrollY, pid: targetPid)
		return ["scrolled": true]
	}

	private func keyPress(_ request: [String: Any]) throws -> [String: Any] {
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "keyPress requires pid in non-intrusive mode", code: "pid_required")
		}
		guard let keys = request["keys"] as? [String], !keys.isEmpty else {
			throw BridgeFailure(message: "keyPress requires at least one key", code: "invalid_args")
		}
		ensureFrontmostForOpaqueFramebuffer(pid: targetPid, windowId: nil)
		try postKeyPress(keys: keys, pid: targetPid)
		// Visual: announce the key the agent just pressed via a small
		// pill near the focused element (preferred) or near the cursor
		// (fallback). If AX exposes no focus and we have no cursor
		// history, the badge is silently dropped - we'd rather render
		// nothing than render at (0,0).
		let label = formatKeypressLabel(keys: keys)
		let anchor = focusedElementAnchor(forPid: targetPid)
		OverlayController.shared.triggerKeypressBadge(label: label, globalPoint: anchor, ownerPid: targetPid)
		return ["pressed": true]
	}

	/// Compact label for a key array. One key passes through; many
	/// collapses to `first ×N` so a burst of arrow keys reads as
	/// `ArrowDown ×5` rather than spamming five badges. Keeps the
	/// pill width bounded.
	private func formatKeypressLabel(keys: [String]) -> String {
		if keys.count == 1 { return keys[0] }
		return "\(keys[0]) ×\(keys.count)"
	}

	/// Best-effort focused-element midpoint for badge anchoring.
	/// Returns nil if the app exposes no focused element or its frame
	/// is degenerate; caller falls back to last cursor position.
	private func focusedElementAnchor(forPid pid: Int32) -> CGPoint? {
		guard let element = focusedElementForPid(pid),
			let frame = frameForElement(element),
			frame.width > 1, frame.height > 1
		else { return nil }
		return CGPoint(x: frame.midX, y: frame.midY)
	}

	private func axPressAtPoint(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		let x = try doubleArg(request, "x")
		let y = try doubleArg(request, "y")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "axPressAtPoint requires pid in non-intrusive mode", code: "pid_required")
		}
		let captureWidth = max(1.0, (try? doubleArg(request, "captureWidth")) ?? 1.0)
		let captureHeight = max(1.0, (try? doubleArg(request, "captureHeight")) ?? 1.0)

		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight, windowFrame: windowFrameArg(request))
		OverlayController.shared.moveTo(globalPoint: point, ownerPid: targetPid)
		OverlayController.shared.triggerClickRing(globalPoint: point, button: .left, ownerPid: targetPid)
		// PID-scoped hit-test so occlusion by other apps doesn't
		// redirect the AX press to whatever sits on top. See note
		// on hitTestElement(at:scopedToPid:).
		guard let hitElement = hitTestElement(at: point, scopedToPid: targetPid) else {
			return ["pressed": false, "reason": "hit_test_failed"]
		}

		let result = performActionOrAncestor(startingAt: hitElement, action: kAXPressAction as CFString, targetPid: targetPid)
		var output: [String: Any] = [
			"pressed": result["performed"] as? Bool ?? false,
		]
		if let reason = result["reason"] as? String {
			output["reason"] = reason
		}
		if let ownerPid = result["ownerPid"] {
			output["ownerPid"] = ownerPid
		}
		return output
	}

	private func axFindTextInput(_ request: [String: Any]) throws -> [String: Any] {
		let pid = Int32(try intArg(request, "pid"))
		ensureEnhancedAccessibility(pid: pid)
		let windowId = optionalIntArg(request, "windowId").map { UInt32($0) }
		let windowRef = optionalStringArg(request, "windowRef")
		guard let window = windowElement(pid: pid, windowId: windowId, windowRef: windowRef) else {
			return ["found": false, "reason": "window_not_found"]
		}
		let textRoles: Set<String> = [
			"AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField",
		]
		let isHybrid = containsWebArea(window: window)
		let elements = collectDescendants(startingAt: window, maxDepth: isHybrid ? 14 : 8)
		let ranked = elements.compactMap { candidate -> (AXUIElement, Double)? in
			let role = self.stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? ""
			var valueSettable = DarwinBoolean(false)
			let valueStatus = AXUIElementIsAttributeSettable(candidate, kAXValueAttribute as CFString, &valueSettable)
			let canSetValue = valueStatus == .success && valueSettable.boolValue
			guard textRoles.contains(role) || canSetValue else { return nil }
			return (candidate, self.scoreTextInputElement(candidate, role: role))
		}.sorted { $0.1 > $1.1 }
		guard let best = ranked.first else {
			return ["found": false, "reason": "no_text_input"]
		}
		return rankedElementPayload(best: best, ranked: ranked, key: "found")
	}

	private func axFocusTextInput(_ request: [String: Any]) throws -> [String: Any] {
		let found = try axFindTextInput(request)
		guard (found["found"] as? Bool) == true, let elementRef = found["elementRef"] as? String else {
			return found
		}
		guard let element = refStore.element(for: elementRef) else {
			return ["focused": false, "reason": "element_ref_invalid"]
		}
		var settable = DarwinBoolean(false)
		let status = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable)
		guard status == .success && settable.boolValue else {
			var payload = found
			payload["focused"] = false
			payload["reason"] = "not_focusable"
			return payload
		}
		let setStatus = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
		var payload = found
		payload["focused"] = (setStatus == .success)
		if setStatus != .success {
			payload["reason"] = "focus_failed"
		} else {
			// Slice 20: keep the overlay cursor honest. The other AX
			// element-targeted commands (axPress, axSetValue, axScroll*)
			// all call syncOverlayToElement on success so the cursor
			// animates to the affected element. Without this, Cmd+L's
			// browser-address-field focus path moved focus invisibly
			// and the next type_text appeared to come from nowhere.
			let ownerPid = optionalIntArg(request, "pid").map { pid_t($0) }
			syncOverlayToElement(element, ownerPid: ownerPid)
		}
		return payload
	}

	private func axListTargets(_ request: [String: Any]) throws -> [String: Any] {
		let pid = Int32(try intArg(request, "pid"))
		ensureEnhancedAccessibility(pid: pid)
		let windowId = optionalIntArg(request, "windowId").map { UInt32($0) }
		let windowRef = optionalStringArg(request, "windowRef")
		let limit = max(1, min(50, optionalIntArg(request, "limit") ?? 12))
		guard let window = windowElement(pid: pid, windowId: windowId, windowRef: windowRef) else {
			return ["targets": [], "reason": "window_not_found"]
		}
		let textRoles: Set<String> = [
			"AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField",
		]
		let structuralRoles: Set<String> = [
			"AXApplication", "AXWindow", "AXToolbar", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXTabGroup", "AXWebArea",
		]
		let browserBundleIds: Set<String> = [
			"com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "net.imput.helium", "org.mozilla.firefox",
		]
		let windowFrame = frameForWindow(window)
		let windowArea = max(1.0, windowFrame.width * windowFrame.height)
		let isBrowser = browserBundleIds.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
		// Treat any window that contains an AXWebArea as a hybrid (Electron, Catalyst-with-web,
		// embedded WebViews). Hybrid apps host their interactive content much deeper than
		// native AppKit hierarchies, and we still want to surface those targets.
		let isHybrid = isBrowser || containsWebArea(window: window)
		let elements = collectDescendants(startingAt: window, maxDepth: isHybrid ? 14 : 8)
		var roleCounts: [String: Int] = [:]
		var rejectedByReason: [String: Int] = [:]
		var eligibleCount = 0
		var visibleFrameCount = 0
		func reject(_ reason: String) {
			rejectedByReason[reason, default: 0] += 1
		}
		var bestByKey: [String: (AXUIElement, Double)] = [:]
		for candidate in elements {
			let role = self.stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? ""
			roleCounts[role.isEmpty ? "(unknown)" : role, default: 0] += 1
			let subrole = self.stringAttribute(candidate, attribute: kAXSubroleAttribute as CFString) ?? ""
			let title = self.stringAttribute(candidate, attribute: kAXTitleAttribute as CFString) ?? ""
			let description = self.stringAttribute(candidate, attribute: kAXDescriptionAttribute as CFString) ?? ""
			let value = self.stringAttribute(candidate, attribute: kAXValueAttribute as CFString) ?? ""
			let actions = self.actionNames(candidate)
			var focusedSettable = DarwinBoolean(false)
			let focusStatus = AXUIElementIsAttributeSettable(candidate, kAXFocusedAttribute as CFString, &focusedSettable)
			let canFocus = focusStatus == .success && focusedSettable.boolValue
			var valueSettable = DarwinBoolean(false)
			let valueStatus = AXUIElementIsAttributeSettable(candidate, kAXValueAttribute as CFString, &valueSettable)
			let canSetValue = valueStatus == .success && valueSettable.boolValue
			let isText = textRoles.contains(role)
			let canPress = actions.contains(kAXPressAction as String)
			let canScroll = self.supportsAnyScrollAction(candidate)
			let canAdjust = actions.contains(kAXIncrementAction as String) || actions.contains(kAXDecrementAction as String)
			if !(isText || canPress || canFocus || canScroll || canAdjust) { reject("not_interactive"); continue }
			guard let frame = self.frameForElement(candidate), frame.width > 10, frame.height > 10 else { reject("no_visible_frame"); continue }
			visibleFrameCount += 1
			let area = frame.width * frame.height
			let label = [title, description, value].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
			let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if structuralRoles.contains(role) {
				if normalizedLabel.isEmpty && !canScroll { reject("unlabeled_structural"); continue }
				if role == "AXWebArea" && !isHybrid { reject("non_browser_web_area"); continue }
			}
			if role == "AXTextArea" || role == "AXTextView" {
				if area > windowArea * 0.55 && !canSetValue { reject("large_unsettable_text_area"); continue }
			}
			if role == "AXButton" && normalizedLabel.isEmpty && !isHybrid { reject("unlabeled_button"); continue }
			if isHybrid && (role == "AXButton" || role == "AXLink" || role == "AXPopUpButton") && normalizedLabel.isEmpty { reject("unlabeled_browser_control"); continue }
			if actions == [kAXShowMenuAction as String] && !isText { reject("show_menu_only"); continue }
			eligibleCount += 1
			var score = 0.0
			if isText {
				score += self.scoreTextInputElement(candidate, role: role)
				if canSetValue {
					score += 160
				} else {
					score -= 80
				}
			}
			if canFocus || canPress {
				score += self.scoreFocusableElement(candidate, role: role, canFocus: canFocus, canPress: canPress, preferredRoles: Set<String>())
			}
			if canScroll { score += 130 }
			if canAdjust { score += 120 }
			if !actions.isEmpty {
				score += self.scoreActionableElement(candidate, role: role, actions: actions, preferredRoles: Set<String>())
			}
			if !normalizedLabel.isEmpty { score += 55 } else if canScroll || canAdjust || role == "AXScrollBar" { score -= 20 } else { score -= 120 }
			if !description.isEmpty { score += 18 }
			if structuralRoles.contains(role) { score -= canScroll ? 40 : 180 }
			if canScroll && role == "AXScrollArea" { score += 180 }
			if canAdjust && role == "AXScrollBar" { score += 180 }
			if area > windowArea * 0.7 && role != "AXTextField" && role != "AXSearchField" && role != "AXComboBox" { score -= 180 }
			if isHybrid && (role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox") { score += 100 }
			if isHybrid && role == "AXLink" { score += 35 }
			if subrole == "AXCloseButton" { score -= 140 }
			if normalizedLabel == "close tab" { score -= 180 }
			if normalizedLabel.count > 160 { score -= 80 }
			if score < 120 { reject("low_score"); continue }
			let key = "\(role)|\(normalizedLabel)|\(Int(frame.midX / 24))|\(Int(frame.midY / 24))"
			if let existing = bestByKey[key], existing.1 >= score { continue }
			bestByKey[key] = (candidate, score)
		}
		// Currently-focused element pre-pass. The model's mental model is "I just
		// focused this control, now I want to act on it." If the focused element
		// is a text input within this window's subtree, surface it unconditionally
		// with a high score so it ranks above generic chrome. This handles the
		// case where focus moved during a prior tool call but the element sits
		// below the depth or scoring cutoff (a real risk in deep hybrid trees).
		var focusedTextSurfaced = false
		let appElement = AXUIElementCreateApplication(pid)
		if let focused = copyAttribute(appElement, attribute: kAXFocusedUIElementAttribute as CFString).flatMap(asAXElement),
			isElement(focused, descendantOf: window)
		{
			let role = self.stringAttribute(focused, attribute: kAXRoleAttribute as CFString) ?? ""
			if textRoles.contains(role) {
				var valueSettable = DarwinBoolean(false)
				let valueStatus = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &valueSettable)
				let canSetValue = valueStatus == .success && valueSettable.boolValue
				if let frame = self.frameForElement(focused), frame.width > 10, frame.height > 10 {
					let title = self.stringAttribute(focused, attribute: kAXTitleAttribute as CFString) ?? ""
					let description = self.stringAttribute(focused, attribute: kAXDescriptionAttribute as CFString) ?? ""
					let value = self.stringAttribute(focused, attribute: kAXValueAttribute as CFString) ?? ""
					let label = [title, description, value].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
					let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
					// Score above the rescue-pass baseline so the focused control wins.
					var score = 600.0
					score += self.scoreTextInputElement(focused, role: role)
					if canSetValue { score += 160 }
					if !normalizedLabel.isEmpty { score += 55 }
					let key = "\(role)|\(normalizedLabel)|\(Int(frame.midX / 24))|\(Int(frame.midY / 24))"
					bestByKey[key] = (focused, score)
					focusedTextSurfaced = true
				}
			}
		}

		// Hybrid text-input rescue pass. Hybrid apps (Electron / Catalyst-with-web)
		// often host their composer/text-area deeper than the bounded BFS reaches.
		// If the bounded walk yielded zero text-input candidates AND the window is
		// hybrid, walk deeper but only collect text-input roles. This keeps native
		// apps free from the cost (their walk is already complete) and only pays
		// the deeper traversal when we'd otherwise return a useless result.
		var rescuePassRan = false
		var rescuedTextInputCount = 0
		let bestHasTextInput = bestByKey.values.contains { tup in
			let role = self.stringAttribute(tup.0, attribute: kAXRoleAttribute as CFString) ?? ""
			return textRoles.contains(role)
		}
		if isHybrid && !bestHasTextInput {
			rescuePassRan = true
			let rescued = collectDescendantsMatching(
				startingAt: window,
				maxDepth: 30,
				maxNodes: 5000,
				where: { element in
					let role = self.stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
					return textRoles.contains(role)
				}
			)
			for candidate in rescued {
				let role = self.stringAttribute(candidate, attribute: kAXRoleAttribute as CFString) ?? ""
				let title = self.stringAttribute(candidate, attribute: kAXTitleAttribute as CFString) ?? ""
				let description = self.stringAttribute(candidate, attribute: kAXDescriptionAttribute as CFString) ?? ""
				let value = self.stringAttribute(candidate, attribute: kAXValueAttribute as CFString) ?? ""
				var valueSettable = DarwinBoolean(false)
				let valueStatus = AXUIElementIsAttributeSettable(candidate, kAXValueAttribute as CFString, &valueSettable)
				let canSetValue = valueStatus == .success && valueSettable.boolValue
				var focusedSettable = DarwinBoolean(false)
				let focusStatus = AXUIElementIsAttributeSettable(candidate, kAXFocusedAttribute as CFString, &focusedSettable)
				let canFocus = focusStatus == .success && focusedSettable.boolValue
				// Skip dead text inputs — if we can't set or focus, they're not
				// actionable anyway and would just clutter the result.
				if !(canSetValue || canFocus) { continue }
				guard let frame = self.frameForElement(candidate), frame.width > 10, frame.height > 10 else { continue }
				// Same large-area sanity guard as the main pass.
				if (role == "AXTextArea" || role == "AXTextView") && frame.width * frame.height > windowArea * 0.55 && !canSetValue { continue }
				let label = [title, description, value].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
				let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				// Score with a high baseline — the model needs the composer
				// to surface above generic chrome buttons. Text inputs are precious in
				// hybrid apps; if we found one this deep, the user almost certainly
				// wants to interact with it.
				var score = 480.0
				score += self.scoreTextInputElement(candidate, role: role)
				if canSetValue { score += 160 }
				if canFocus { score += 40 }
				if !normalizedLabel.isEmpty { score += 55 }
				if !description.isEmpty { score += 18 }
				let key = "\(role)|\(normalizedLabel)|\(Int(frame.midX / 24))|\(Int(frame.midY / 24))"
				if let existing = bestByKey[key], existing.1 >= score { continue }
				bestByKey[key] = (candidate, score)
				rescuedTextInputCount += 1
			}
		}

		let ranked = bestByKey.values.sorted { $0.1 > $1.1 }
		let topRoles = roleCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(16)
		var diagnostics: [String: Any] = [
			"axTreeNodeCount": elements.count,
			"visibleInteractiveNodeCount": visibleFrameCount,
			"eligibleNodeCount": eligibleCount,
			"rankedNodeCount": ranked.count,
			"returnedTargetCount": min(limit, ranked.count),
			"roleCounts": Dictionary(uniqueKeysWithValues: topRoles.map { ($0.key, $0.value) }),
			"rejectedByReason": rejectedByReason,
		]
		if rescuePassRan {
			diagnostics["hybridTextInputRescue"] = [
				"ran": true,
				"recoveredCount": rescuedTextInputCount,
			]
		}
		if focusedTextSurfaced {
			diagnostics["focusedTextSurfaced"] = true
		}
		return ["targets": Array(ranked.prefix(limit)).map { self.elementPayload(element: $0.0, key: "target", score: $0.1) }, "diagnostics": diagnostics]
	}

	private func axPressElement(_ request: [String: Any]) throws -> [String: Any] {
		let elementRef = try stringArg(request, "elementRef")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "axPressElement requires pid in non-intrusive mode", code: "pid_required")
		}
		guard let element = refStore.element(for: elementRef) else {
			return ["pressed": false, "reason": "element_ref_invalid"]
		}
		syncOverlayToElement(element, ownerPid: targetPid)
		if let frame = frameForElement(element) {
			OverlayController.shared.triggerClickRing(globalPoint: CGPoint(x: frame.midX, y: frame.midY), button: .left, ownerPid: targetPid)
		}
		let result = performActionOrAncestor(startingAt: element, action: kAXPressAction as CFString, targetPid: targetPid)
		var output: [String: Any] = ["pressed": result["performed"] as? Bool ?? false]
		if let reason = result["reason"] as? String {
			output["reason"] = reason
		}
		if let ownerPid = result["ownerPid"] {
			output["ownerPid"] = ownerPid
		}
		return output
	}

	private func axPerformActionElement(_ request: [String: Any]) throws -> [String: Any] {
		let elementRef = try stringArg(request, "elementRef")
		let action = try axActionName(try stringArg(request, "action"))
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "axPerformActionElement requires pid in non-intrusive mode", code: "pid_required")
		}
		guard let element = refStore.element(for: elementRef) else {
			return ["performed": false, "reason": "element_ref_invalid"]
		}
		syncOverlayToElement(element, ownerPid: targetPid)
		if let frame = frameForElement(element) {
			OverlayController.shared.triggerClickRing(globalPoint: CGPoint(x: frame.midX, y: frame.midY), button: .left, ownerPid: targetPid)
		}
		return performActionOrAncestor(startingAt: element, action: action, targetPid: targetPid)
	}

	private func axFocusElement(_ request: [String: Any]) throws -> [String: Any] {
		let elementRef = try stringArg(request, "elementRef")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "axFocusElement requires pid in non-intrusive mode", code: "pid_required")
		}
		guard let element = refStore.element(for: elementRef) else {
			return ["focused": false, "reason": "element_ref_invalid"]
		}
		syncOverlayToElement(element, ownerPid: targetPid)
		return focusElementOrAncestor(startingAt: element, targetPid: targetPid)
	}

	private func axFocusAtPoint(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		let x = try doubleArg(request, "x")
		let y = try doubleArg(request, "y")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "axFocusAtPoint requires pid in non-intrusive mode", code: "pid_required")
		}
		let captureWidth = max(1.0, (try? doubleArg(request, "captureWidth")) ?? 1.0)
		let captureHeight = max(1.0, (try? doubleArg(request, "captureHeight")) ?? 1.0)

		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight, windowFrame: windowFrameArg(request))
		OverlayController.shared.moveTo(globalPoint: point, ownerPid: targetPid)
		// PID-scoped hit-test so occlusion by other apps doesn't
		// redirect the AX focus to whatever sits on top.
		guard let hitElement = hitTestElement(at: point, scopedToPid: targetPid) else {
			return ["focused": false, "reason": "hit_test_failed"]
		}

		return focusElementOrAncestor(startingAt: hitElement, targetPid: targetPid)
	}

	private func axScrollElement(_ request: [String: Any]) throws -> [String: Any] {
		let elementRef = try stringArg(request, "elementRef")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "axScrollElement requires pid in non-intrusive mode", code: "pid_required")
		}
		guard let element = refStore.element(for: elementRef) else {
			return ["scrolled": false, "reason": "element_ref_invalid"]
		}
		syncOverlayToElement(element, ownerPid: targetPid)
		let scrollX = optionalIntArg(request, "scrollX") ?? 0
		let scrollY = optionalIntArg(request, "scrollY") ?? 0
		// Anchor the chevrons on the element midpoint when AX has a
		// frame; the controller falls back to lastGlobalPoint otherwise.
		if let frame = frameForElement(element) {
			OverlayController.shared.triggerScrollEffect(globalPoint: CGPoint(x: frame.midX, y: frame.midY), deltaX: scrollX, deltaY: scrollY, ownerPid: targetPid)
		}
		return performScrollActionOrAncestor(startingAt: element, targetPid: targetPid, scrollX: scrollX, scrollY: scrollY, steps: max(1, min(8, optionalIntArg(request, "steps") ?? 1)))
	}

	private func axScrollAtPoint(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = UInt32(try intArg(request, "windowId"))
		let x = try doubleArg(request, "x")
		let y = try doubleArg(request, "y")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "axScrollAtPoint requires pid in non-intrusive mode", code: "pid_required")
		}
		let captureWidth = max(1.0, (try? doubleArg(request, "captureWidth")) ?? 1.0)
		let captureHeight = max(1.0, (try? doubleArg(request, "captureHeight")) ?? 1.0)
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight, windowFrame: windowFrameArg(request))
		OverlayController.shared.moveTo(globalPoint: point, ownerPid: targetPid)
		let scrollX = optionalIntArg(request, "scrollX") ?? 0
		let scrollY = optionalIntArg(request, "scrollY") ?? 0
		OverlayController.shared.triggerScrollEffect(globalPoint: point, deltaX: scrollX, deltaY: scrollY, ownerPid: targetPid)
		// PID-scoped hit-test so occlusion by other apps doesn't
		// redirect the scroll target to whatever sits on top. The
		// agent's intent is "scroll the element under (x,y) in this
		// app" regardless of which app's window is frontmost.
		guard let hitElement = hitTestElement(at: point, scopedToPid: targetPid) else {
			return ["scrolled": false, "reason": "hit_test_failed"]
		}
		return performScrollActionOrAncestor(startingAt: hitElement, targetPid: targetPid, scrollX: scrollX, scrollY: scrollY, steps: max(1, min(8, optionalIntArg(request, "steps") ?? 1)))
	}

	/// Move the overlay cursor to the visual center of an AX element if
	/// the element exposes a frame. Used by `*Element` AX commands so
	/// click({ ref }) animates the cursor to the right place even when
	/// no raw coordinate was supplied.
	private func syncOverlayToElement(_ element: AXUIElement, ownerPid: pid_t? = nil) {
		guard let frame = frameForElement(element) else { return }
		let center = CGPoint(x: frame.midX, y: frame.midY)
		OverlayController.shared.moveTo(globalPoint: center, ownerPid: ownerPid)
	}

	private func hitTestElement(at point: CGPoint) -> AXUIElement? {
		let systemWide = AXUIElementCreateSystemWide()
		var hitElement: AXUIElement?
		let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitElement)
		guard status == .success, let hitElement else { return nil }
		return hitElement
	}

	/// PID-scoped hit-test. AXUIElementCopyElementAtPosition on an
	/// application element returns whichever element in that app
	/// occupies the point — it ignores z-order occlusion by other
	/// apps. This is what we want for the stealth contract: the
	/// agent is targeting a specific window in a specific app, and
	/// the fact that iTerm2 / Chrome / another app sits on top of
	/// it must not redirect the AX action to that other app.
	///
	/// Falls back to the system-wide hit-test if the app element
	/// returns nothing — some apps (heavy custom drawing, web
	/// content) don't expose their content via AX at all, and the
	/// system-wide path may still find something useful.
	private func hitTestElement(at point: CGPoint, scopedToPid pid: Int32) -> AXUIElement? {
		let appElement = AXUIElementCreateApplication(pid)
		var hitElement: AXUIElement?
		let status = AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hitElement)
		if status == .success, let hitElement {
			return hitElement
		}
		return nil
	}

	private func axActionName(_ actionName: String) throws -> CFString {
		switch actionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "press":
			return kAXPressAction as CFString
		case "increment":
			return kAXIncrementAction as CFString
		case "decrement":
			return kAXDecrementAction as CFString
		case "confirm":
			return kAXConfirmAction as CFString
		case "cancel":
			return kAXCancelAction as CFString
		case "showmenu", "show_menu", "menu":
			return kAXShowMenuAction as CFString
		case "pick":
			return kAXPickAction as CFString
		default:
			throw BridgeFailure(message: "Unsupported AX action '\(actionName)'", code: "invalid_args")
		}
	}

	private let axScrollDownAction = "AXScrollDown" as CFString
	private let axScrollUpAction = "AXScrollUp" as CFString
	private let axScrollLeftAction = "AXScrollLeft" as CFString
	private let axScrollRightAction = "AXScrollRight" as CFString

	private func scrollActionNames(scrollX: Int, scrollY: Int) -> [CFString] {
		var actions: [CFString] = []
		if scrollY > 0 { actions.append(axScrollDownAction) }
		if scrollY < 0 { actions.append(axScrollUpAction) }
		if scrollX > 0 { actions.append(axScrollRightAction) }
		if scrollX < 0 { actions.append(axScrollLeftAction) }
		return actions
	}

	private func supportsAnyScrollAction(_ element: AXUIElement) -> Bool {
		let actions = Set(actionNames(element))
		return actions.contains(axScrollDownAction as String) || actions.contains(axScrollUpAction as String) || actions.contains(axScrollLeftAction as String) || actions.contains(axScrollRightAction as String)
	}

	private func performScrollActionOrAncestor(startingAt element: AXUIElement, targetPid: Int32, scrollX: Int, scrollY: Int, steps: Int) -> [String: Any] {
		let actions = scrollActionNames(scrollX: scrollX, scrollY: scrollY)
		guard !actions.isEmpty else { return ["scrolled": false, "reason": "zero_delta"] }
		var current: AXUIElement? = element
		var depth = 0

		while let candidate = current, depth < 10 {
			if let pid = pidForElement(candidate), pid != targetPid {
				return ["scrolled": false, "reason": "pid_mismatch", "ownerPid": Int(pid)]
			}
			var didScroll = false
			for _ in 0..<steps {
				for action in actions where supportsAction(candidate, action: action) {
					let status = AXUIElementPerformAction(candidate, action)
					if status == .success { didScroll = true }
				}
			}
			if didScroll { return ["scrolled": true] }
			current = parentElement(candidate)
			depth += 1
		}

		return ["scrolled": false, "reason": "no_scroll_action"]
	}

	private func performActionOrAncestor(startingAt element: AXUIElement, action: CFString, targetPid: Int32) -> [String: Any] {
		var current: AXUIElement? = element
		var depth = 0

		while let candidate = current, depth < 10 {
			if let pid = pidForElement(candidate), pid != targetPid {
				return ["performed": false, "reason": "pid_mismatch", "ownerPid": Int(pid)]
			}

			if supportsAction(candidate, action: action) {
				let actionStatus = AXUIElementPerformAction(candidate, action)
				if actionStatus == .success {
					return ["performed": true]
				}
			}

			current = parentElement(candidate)
			depth += 1
		}

		return ["performed": false, "reason": "no_matching_action"]
	}

	private func focusElementOrAncestor(startingAt element: AXUIElement, targetPid: Int32) -> [String: Any] {
		var current: AXUIElement? = element
		var depth = 0

		while let candidate = current, depth < 10 {
			if let pid = pidForElement(candidate), pid != targetPid {
				return ["focused": false, "reason": "pid_mismatch", "ownerPid": Int(pid)]
			}

			var settable = DarwinBoolean(false)
			let status = AXUIElementIsAttributeSettable(candidate, kAXFocusedAttribute as CFString, &settable)
			if status == .success && settable.boolValue {
				let setStatus = AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				if setStatus == .success {
					return ["focused": true]
				}
			}

			current = parentElement(candidate)
			depth += 1
		}

		return ["focused": false, "reason": "no_focusable_ancestor"]
	}

	private func windowElement(pid: Int32, windowId: UInt32?, windowRef: String? = nil) -> AXUIElement? {
		if let windowRef, let stored = refStore.window(for: windowRef) {
			AXUIElementSetMessagingTimeout(stored, 1.0)
			var ownerPid: pid_t = 0
			if AXUIElementGetPid(stored, &ownerPid) == .success, ownerPid == pid {
				return stored
			}
		}

		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 1.0)
		let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
		guard !windows.isEmpty else { return nil }
		guard let windowId else {
			return windows.first
		}
		let candidates = cgWindowCandidates(pid: pid)
		for window in windows {
			let title = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
			let frame = frameForWindow(window)
			if let candidate = bestCandidate(frame: frame, title: title, candidates: candidates, usedIds: []), candidate.windowId == windowId {
				return window
			}
		}
		return nil
	}

	private func findDescendant(startingAt root: AXUIElement, maxDepth: Int, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
		collectDescendants(startingAt: root, maxDepth: maxDepth).first(where: predicate)
	}

	private func collectDescendants(startingAt root: AXUIElement, maxDepth: Int, maxNodes: Int = 5000) -> [AXUIElement] {
		var queue: [(AXUIElement, Int)] = [(root, 0)]
		var index = 0
		var output: [AXUIElement] = []
		while index < queue.count {
			if output.count >= maxNodes { break }
			let (element, depth) = queue[index]
			index += 1
			output.append(element)
			if depth >= maxDepth { continue }
			let children = axElementArray(element, attribute: kAXChildrenAttribute as CFString)
			for child in children {
				queue.append((child, depth + 1))
			}
		}
		return output
	}

	/// BFS variant that walks deep but only retains nodes matching `where`. Used
	/// for targeted second-pass rescues (e.g. hybrid app text inputs hosted
	/// inside an AXWebArea well below the bounded walk's depth cap). Walk depth
	/// is capped by `maxDepth`; total nodes visited is capped by `maxNodes`.
	private func collectDescendantsMatching(
		startingAt root: AXUIElement,
		maxDepth: Int,
		maxNodes: Int = 5000,
		where predicate: (AXUIElement) -> Bool
	) -> [AXUIElement] {
		var queue: [(AXUIElement, Int)] = [(root, 0)]
		var index = 0
		var visited = 0
		var output: [AXUIElement] = []
		while index < queue.count {
			if visited >= maxNodes { break }
			let (element, depth) = queue[index]
			index += 1
			visited += 1
			if predicate(element) { output.append(element) }
			if depth >= maxDepth { continue }
			let children = axElementArray(element, attribute: kAXChildrenAttribute as CFString)
			for child in children {
				queue.append((child, depth + 1))
			}
		}
		return output
	}

	/// Cheap BFS that returns true if the window's AX subtree contains an
	/// `AXWebArea` within `withinDepth` levels. Used to detect Electron /
	/// Catalyst-with-web-content / Slack-style hybrid apps so we can apply
	/// browser-style depth and acceptance policy without bundle-id allowlists.
	private func containsWebArea(window: AXUIElement, withinDepth: Int = 8) -> Bool {
		var queue: [(AXUIElement, Int)] = [(window, 0)]
		var index = 0
		var visited = 0
		while index < queue.count {
			if visited >= 800 { break }
			let (element, depth) = queue[index]
			index += 1
			visited += 1
			let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
			if role == "AXWebArea" { return true }
			if depth >= withinDepth { continue }
			let children = axElementArray(element, attribute: kAXChildrenAttribute as CFString)
			for child in children {
				queue.append((child, depth + 1))
			}
		}
		return false
	}

	private func scoreTextInputElement(_ element: AXUIElement, role: String) -> Double {
		var score = 0.0
		if role == "AXSearchField" { score += 120 }
		if role == "AXTextField" { score += 100 }
		if role == "AXComboBox" { score += 80 }
		if role == "AXTextArea" || role == "AXTextView" || role == "AXEditableText" { score += 70 }
		if role == "AXSecureTextField" { score -= 40 }
		if let frame = frameForElement(element) {
			score += min(120, Double(frame.width * frame.height) / 5000.0)
			if frame.width > 40 && frame.height > 16 { score += 20 }
			if frame.origin.y < 220 { score += 15 }
		} else {
			score -= 100
		}
		let title = stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
		let value = stringAttribute(element, attribute: kAXValueAttribute as CFString) ?? ""
		if !title.isEmpty { score += 10 }
		if !value.isEmpty { score += 5 }
		return score
	}

	private func scoreFocusableElement(
		_ element: AXUIElement,
		role: String,
		canFocus: Bool,
		canPress: Bool,
		preferredRoles: Set<String>
	) -> Double {
		var score = 0.0
		if canPress { score += 80 }
		if canFocus { score += 70 }
		if !preferredRoles.isEmpty && preferredRoles.contains(role) { score += 40 }
		switch role {
		case "AXButton": score += 60
		case "AXTextField", "AXSearchField", "AXTextArea", "AXTextView": score += 50
		case "AXList", "AXOutline", "AXRow", "AXCell", "AXLink": score += 35
		case "AXGroup", "AXToolbar", "AXWindow", "AXApplication": score -= 60
		default: break
		}
		if let frame = frameForElement(element) {
			score += min(100, Double(frame.width * frame.height) / 6000.0)
			if frame.width > 24 && frame.height > 14 { score += 10 }
		} else {
			score -= 100
		}
		if !actionNames(element).isEmpty { score += 10 }
		return score
	}

	private func scoreActionableElement(
		_ element: AXUIElement,
		role: String,
		actions: [String],
		preferredRoles: Set<String>
	) -> Double {
		var score = 0.0
		if !preferredRoles.isEmpty && preferredRoles.contains(role) { score += 40 }
		if actions.contains(kAXPressAction as String) { score += 100 }
		if actions.contains(kAXShowMenuAction as String) { score += 50 }
		if actions.contains(kAXPickAction as String) { score += 45 }
		if actions.contains(kAXConfirmAction as String) { score += 35 }
		if actions.contains(kAXIncrementAction as String) { score += 55 }
		if actions.contains(kAXDecrementAction as String) { score += 55 }
		switch role {
		case "AXButton": score += 70
		case "AXLink": score += 60
		case "AXScrollBar": score += 80
		case "AXRow", "AXCell", "AXList", "AXOutline": score += 40
		case "AXGroup", "AXToolbar", "AXWindow", "AXApplication": score -= 60
		default: break
		}
		if let frame = frameForElement(element) {
			score += min(100, Double(frame.width * frame.height) / 6000.0)
			if frame.width > 20 && frame.height > 14 { score += 10 }
		} else {
			score -= 100
		}
		if !actions.isEmpty { score += Double(min(actions.count, 5) * 4) }
		return score
	}

	private func frameForElement(_ element: AXUIElement) -> CGRect? {
		let origin = pointAttribute(element, attribute: kAXPositionAttribute as CFString)
		let size = sizeAttribute(element, attribute: kAXSizeAttribute as CFString)
		guard let origin, let size, size.width > 0, size.height > 0 else { return nil }
		return CGRect(origin: origin, size: size)
	}

	private func rankedElementPayload(best: (AXUIElement, Double), ranked: [(AXUIElement, Double)], key: String) -> [String: Any] {
		var payload = elementPayload(element: best.0, key: key, score: best.1)
		payload["confidence"] = confidenceLabel(ranked)
		payload["candidates"] = Array(ranked.prefix(3)).map { candidate, score in
			candidateSummary(element: candidate, score: score)
		}
		return payload
	}

	private func confidenceLabel(_ ranked: [(AXUIElement, Double)]) -> String {
		guard let first = ranked.first else { return "none" }
		guard ranked.count > 1 else { return "high" }
		let delta = first.1 - ranked[1].1
		if delta >= 40 { return "high" }
		if delta >= 15 { return "medium" }
		return "low"
	}

	private func candidateSummary(element: AXUIElement, score: Double) -> [String: Any] {
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		let title = stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
		let description = stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? ""
		let value = stringAttribute(element, attribute: kAXValueAttribute as CFString) ?? ""
		var summary: [String: Any] = [
			"role": role,
			"subrole": subrole,
			"title": title,
			"description": description,
			"value": value,
			"score": score,
			"actions": actionNames(element),
		]
		if let frame = frameForElement(element) {
			summary["frame"] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
		}
		return summary
	}

	private func elementPayload(element: AXUIElement, key: String, score: Double? = nil) -> [String: Any] {
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		let title = stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
		let description = stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? ""
		let value = stringAttribute(element, attribute: kAXValueAttribute as CFString) ?? ""
		let frame = frameForElement(element)
		let centerX = frame.map { $0.midX } ?? 0
		let centerY = frame.map { $0.midY } ?? 0
		var valueSettable = DarwinBoolean(false)
		let valueStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
		var focusedSettable = DarwinBoolean(false)
		let focusedStatus = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusedSettable)
		let actions = actionNames(element)
		let canSetValue = valueStatus == .success && valueSettable.boolValue
		let textRoles: Set<String> = [
			"AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField",
		]
		var payload: [String: Any] = [
			key: true,
			"elementRef": refStore.storeElement(element),
			"role": role,
			"subrole": subrole,
			"title": title,
			"description": description,
			"value": value,
			"actions": actions,
			"isTextInput": textRoles.contains(role),
			"canSetValue": canSetValue,
			"canFocus": focusedStatus == .success && focusedSettable.boolValue,
			"canPress": actions.contains(kAXPressAction as String),
			"canScroll": supportsAnyScrollAction(element),
			"canIncrement": actions.contains(kAXIncrementAction as String),
			"canDecrement": actions.contains(kAXDecrementAction as String),
			"x": centerX,
			"y": centerY,
		]
		if let frame {
			payload["frame"] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
		}
		if let score {
			payload["score"] = score
		}
		return payload
	}

	private func pidForElement(_ element: AXUIElement) -> Int32? {
		var pid: pid_t = 0
		let status = AXUIElementGetPid(element, &pid)
		guard status == .success else { return nil }
		return Int32(pid)
	}

	private func parentElement(_ element: AXUIElement) -> AXUIElement? {
		guard let value = copyAttribute(element, attribute: kAXParentAttribute as CFString) else {
			return nil
		}
		return asAXElement(value)
	}

	private func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
		CFEqual(lhs as CFTypeRef, rhs as CFTypeRef)
	}

	private func isElement(_ element: AXUIElement, descendantOf ancestor: AXUIElement) -> Bool {
		var current: AXUIElement? = element
		var depth = 0
		while let candidate = current, depth < 20 {
			if sameElement(candidate, ancestor) {
				return true
			}
			current = parentElement(candidate)
			depth += 1
		}
		return false
	}

	private func actionNames(_ element: AXUIElement) -> [String] {
		var actionsValue: CFArray?
		let status = AXUIElementCopyActionNames(element, &actionsValue)
		guard status == .success else { return [] }
		guard let actionsArray = actionsValue as? [AnyObject] else { return [] }
		return actionsArray.compactMap { $0 as? String }
	}

	private func supportsAction(_ element: AXUIElement, action: CFString) -> Bool {
		actionNames(element).contains(action as String)
	}

	private func focusedElement(_ request: [String: Any]) throws -> [String: Any] {
		let pid = Int32(try intArg(request, "pid"))
		let windowId = optionalIntArg(request, "windowId").map { UInt32($0) }
		let windowRef = optionalStringArg(request, "windowRef")
		let app = AXUIElementCreateApplication(pid)
		guard let focusedValue = copyAttribute(app, attribute: kAXFocusedUIElementAttribute as CFString),
			let element = asAXElement(focusedValue)
		else {
			return ["exists": false]
		}
		if windowId != nil || windowRef != nil {
			guard let window = windowElement(pid: pid, windowId: windowId, windowRef: windowRef) else {
				return ["exists": false, "reason": "window_not_found"]
			}
			guard isElement(element, descendantOf: window) else {
				return ["exists": false, "reason": "focused_element_outside_window"]
			}
		}

		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"

		var settable = DarwinBoolean(false)
		let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
		let canSetValue = settableStatus == .success && settable.boolValue

		let textRoles: Set<String> = [
			"AXTextField",
			"AXTextArea",
			"AXTextView",
			"AXSearchField",
			"AXComboBox",
			"AXEditableText",
			"AXSecureTextField",
		]

		let isTextInput = textRoles.contains(role) || canSetValue
		let elementRef = refStore.storeElement(element)

		return [
			"exists": true,
			"elementRef": elementRef,
			"role": role,
			"subrole": subrole,
			"isTextInput": isTextInput,
			"isSecure": secure,
			"canSetValue": canSetValue,
		]
	}

	private func setValue(_ request: [String: Any]) throws -> [String: Any] {
		let elementRef = try stringArg(request, "elementRef")
		let value = try stringArg(request, "value")
		guard let element = refStore.element(for: elementRef) else {
			throw BridgeFailure(message: "Element reference is no longer valid", code: "element_ref_invalid")
		}

		let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
		if status != .success {
			throw BridgeFailure(message: "Failed to set value (AX error \(status.rawValue))", code: "set_value_failed")
		}
		// Visual: outline the field that was just populated. Look up the
		// element's owning PID so the occlusion check can target it; AX
		// exposes this on every element via kAXPIDAttribute.
		var elementPid: pid_t = 0
		_ = AXUIElementGetPid(element, &elementPid)
		OverlayController.shared.triggerTypeFlash(globalRect: frameForElement(element), ownerPid: elementPid > 0 ? elementPid : nil)
		return ["set": true]
	}

	private func typeText(_ request: [String: Any]) throws -> [String: Any] {
		let text = try stringArg(request, "text")
		guard let targetPid = optionalIntArg(request, "pid").map({ Int32($0) }) else {
			throw BridgeFailure(message: "typeText requires pid in non-intrusive mode", code: "pid_required")
		}
		try postUnicodeText(text, pid: targetPid)
		// Visual: try to outline the focused element if AX exposes one;
		// otherwise the controller draws a small pill near the cursor.
		let focused = focusedElementForPid(targetPid)
		let focusedRect = focused.flatMap { frameForElement($0) }
		OverlayController.shared.triggerTypeFlash(globalRect: focusedRect, ownerPid: targetPid)
		return ["typed": true]
	}

	/// Best-effort fetch of the currently focused element for a target
	/// PID's app. Returns nil if the app exposes no focused element or
	/// AX times out. Used by typeText to anchor the type-flash effect.
	private func focusedElementForPid(_ pid: Int32) -> AXUIElement? {
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 1.0)
		var focused: AnyObject?
		let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
		guard status == .success, let focused = focused else { return nil }
		let cf = focused as CFTypeRef
		guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
		return unsafeBitCast(cf, to: AXUIElement.self)
	}

	private func getMousePosition() -> [String: Any] {
		let position = NSEvent.mouseLocation
		return ["x": position.x, "y": position.y]
	}

	private func copyAttribute(_ element: AXUIElement, attribute: CFString) -> AnyObject? {
		var value: AnyObject?
		let status = AXUIElementCopyAttributeValue(element, attribute, &value)
		guard status == .success else { return nil }
		return value
	}

	private func boolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
		guard let value = copyAttribute(element, attribute: attribute) else { return nil }
		if let boolValue = value as? Bool {
			return boolValue
		}
		if let number = value as? NSNumber {
			return number.boolValue
		}
		return nil
	}

	private func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
		copyAttribute(element, attribute: attribute) as? String
	}

	private func axElementArray(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
		guard let value = copyAttribute(element, attribute: attribute) else { return [] }
		if let array = value as? [AXUIElement] {
			return array
		}
		if let anyArray = value as? [AnyObject] {
			return anyArray.compactMap(asAXElement)
		}
		return []
	}

	private func asAXElement(_ value: AnyObject) -> AXUIElement? {
		let cfValue = value as CFTypeRef
		guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
		return unsafeBitCast(cfValue, to: AXUIElement.self)
	}

	private func pointAttribute(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
		guard let value = copyAttribute(element, attribute: attribute) else { return nil }
		let cfValue = value as CFTypeRef
		guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
		let axValue = unsafeBitCast(cfValue, to: AXValue.self)
		guard AXValueGetType(axValue) == .cgPoint else { return nil }
		var point = CGPoint.zero
		guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
		return point
	}

	private func sizeAttribute(_ element: AXUIElement, attribute: CFString) -> CGSize? {
		guard let value = copyAttribute(element, attribute: attribute) else { return nil }
		let cfValue = value as CFTypeRef
		guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
		let axValue = unsafeBitCast(cfValue, to: AXValue.self)
		guard AXValueGetType(axValue) == .cgSize else { return nil }
		var size = CGSize.zero
		guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
		return size
	}

	private func frameForWindow(_ window: AXUIElement) -> CGRect {
		let origin = pointAttribute(window, attribute: kAXPositionAttribute as CFString) ?? .zero
		let size = sizeAttribute(window, attribute: kAXSizeAttribute as CFString) ?? .zero
		return CGRect(origin: origin, size: size)
	}

	/// Single-window onscreen probe via CGWindowList. Returns nil when
	/// the window isn't in CGWindowList (already gone). Returns true
	/// when kCGWindowIsOnscreen is present and true; false otherwise
	/// (off-Space, fully occluded, or minimized). Cheap: microseconds.
	private func isWindowOnscreen(windowId: UInt32) -> Bool? {
		guard let entries = CGWindowListCopyWindowInfo([.optionIncludingWindow, .optionAll], CGWindowID(windowId)) as? [[String: Any]],
			let first = entries.first(where: { ((($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value) ?? 0) == windowId })
		else {
			return nil
		}
		return (first[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
	}

	private func cgWindowCandidates(pid: Int32) -> [CGWindowCandidate] {
		guard let entries = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
			return []
		}

		var candidates: [CGWindowCandidate] = []
		for entry in entries {
			guard let ownerPid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
				ownerPid == pid
			else {
				continue
			}
			let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
			if layer != 0 { continue }

			guard let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
				continue
			}
			guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
				let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
			else {
				continue
			}

			let title = (entry[kCGWindowName as String] as? String) ?? ""
			// kCGWindowIsOnscreen is documented as only being present when
			// the window is on-screen. A missing value therefore means the
			// window is off-screen (most commonly because it lives on a
			// different macOS Space). We previously defaulted missing -> true
			// which made every off-Space window look on-screen.
			let isOnscreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
			candidates.append(
				CGWindowCandidate(
					windowId: windowNumber,
					title: title,
					bounds: bounds,
					isOnscreen: isOnscreen
				)
			)
		}
		return candidates
	}

	private func bestCandidate(
		frame: CGRect,
		title: String,
		candidates: [CGWindowCandidate],
		usedIds: Set<UInt32>
	) -> CGWindowCandidate? {
		var best: (candidate: CGWindowCandidate, score: Double)?
		let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

		for candidate in candidates where !usedIds.contains(candidate.windowId) {
			var score = 0.0
			let candidateTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if !normalizedTitle.isEmpty {
				if candidateTitle == normalizedTitle {
					score += 100
				} else if candidateTitle.contains(normalizedTitle) {
					score += 50
				}
			}

			let dx = abs(candidate.bounds.origin.x - frame.origin.x)
			let dy = abs(candidate.bounds.origin.y - frame.origin.y)
			let dw = abs(candidate.bounds.size.width - frame.size.width)
			let dh = abs(candidate.bounds.size.height - frame.size.height)
			score -= Double(dx + dy + dw + dh) / 20.0

			if let currentBest = best {
				if score > currentBest.score {
					best = (candidate, score)
				}
			} else {
				best = (candidate, score)
			}
		}

		return best?.candidate
	}

	private func displayScaleFactor(for frame: CGRect) -> Double {
		var displayCount: UInt32 = 0
		guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
			return Double(NSScreen.main?.backingScaleFactor ?? 1.0)
		}

		var displays = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
		guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
			return Double(NSScreen.main?.backingScaleFactor ?? 1.0)
		}

		var chosenDisplay: CGDirectDisplayID?
		var chosenArea: CGFloat = -1
		for display in displays {
			let bounds = CGDisplayBounds(display)
			let overlap = bounds.intersection(frame)
			let area = overlap.isNull ? 0 : overlap.width * overlap.height
			if area > chosenArea {
				chosenArea = area
				chosenDisplay = display
			}
		}

		guard let display = chosenDisplay, let mode = CGDisplayCopyDisplayMode(display) else {
			return Double(NSScreen.main?.backingScaleFactor ?? 1.0)
		}

		let width = Double(mode.width)
		guard width > 0 else { return 1.0 }
		let scale = Double(mode.pixelWidth) / width
		return scale > 0 ? scale : 1.0
	}

	private func captureWindow(windowId: UInt32) throws -> [String: Any] {
		guard #available(macOS 14.0, *) else {
			throw BridgeFailure(message: "Window capture requires macOS 14+", code: "unsupported_os")
		}

		// Fast off-Space gate. SCScreenshotManager.captureImage hangs
		// indefinitely (well past pi's 25s helper timeout, observed >30s)
		// when the target window lives on a different macOS Space - the
		// system never produces a frame because off-Space windows don't
		// render. We can detect this in a single CGWindowList lookup
		// (microseconds) and fail fast with a useful recovery message,
		// rather than letting pi SIGTERM the helper.
		//
		// Brief retry to absorb the surface_window race: just after
		// activate + AXRaise, CGWindowList can still report
		// kCGWindowIsOnscreen=false for ~200-500ms while the window-server
		// commits the transition. surfaceWindow already settles before
		// returning, but the agent might call screenshot directly without
		// going through surfaceWindow (e.g. user manually switched Spaces
		// to bring the window forward). 6 polls @ 50ms = 300ms max latency
		// when the window is genuinely off-Space - far cheaper than the
		// 25s SIGTERM and matches what humans expect a "is it visible?"
		// check to feel like.
		var lastSeenOnscreen: Bool? = isWindowOnscreen(windowId: windowId)
		if lastSeenOnscreen == false {
			for _ in 0..<6 {
				Thread.sleep(forTimeInterval: 0.05)
				let probe = isWindowOnscreen(windowId: windowId)
				if probe != false {
					lastSeenOnscreen = probe
					break
				}
			}
		}
		if lastSeenOnscreen == false {
			throw BridgeFailure(
				message: "Window \(windowId) is on a different macOS Space and cannot be screenshotted - SCScreenshotManager hangs on off-Space windows. Use wake_window({windowRef}) to see non-GUI alternatives (apple_script, app_instructions), or ask the user for permission and call surface_window({windowRef}) to bring the window forward, then retry screenshot.",
				code: "window_off_active_space"
			)
		}

		let semaphore = DispatchSemaphore(value: 0)
		let capturedImage = Box<CGImage?>(nil)
		let capturedError = Box<Error?>(nil)

		let task = Task {
			defer { semaphore.signal() }
			do {
				if Task.isCancelled {
					return
				}
				let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
				guard let window = shareable.windows.first(where: { $0.windowID == windowId }) else {
					throw BridgeFailure(message: "Window \(windowId) is not available for capture", code: "window_not_found")
				}

				let filter = SCContentFilter(desktopIndependentWindow: window)
				let config = SCStreamConfiguration()
				config.showsCursor = false
				if #available(macOS 14.0, *) {
					config.ignoreShadowsSingleWindow = true
				}
				// Default SCStreamConfiguration width/height is 0, which
				// SCScreenshotManager interprets as the full display - so
				// without this we capture a 1920x1080 image with the
				// window as a small region inside a transparent frame.
				// Set the pixel dimensions to the window's logical size
				// times the display backing scale so the image matches the
				// window exactly. This makes the image: pixel = window: point
				// relationship clean and the scale field meaningful.
				let wScale = displayScaleFactor(for: window.frame)
				config.width = max(1, Int((window.frame.width * wScale).rounded()))
				config.height = max(1, Int((window.frame.height * wScale).rounded()))

				let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
				capturedImage.value = image
			} catch {
				capturedError.value = error
			}
		}

		// SCK fast-path. We give it 3s instead of the previous 8s -
		// SCK is the high-quality path but it can wedge under load (two
		// pi sessions racing, GPU-heavy frontmost app like a UTM VM,
		// post-Sleep window-server thrash). The cgWindowScreenshot
		// fallback below typically returns in 200ms and produces an
		// image suitable for both vision and the agent's coordinate
		// envelope. Net effect: bound the worst-case wait so we never
		// burn pi's 25s helper-command timeout on SCK alone, leaving
		// no headroom for the fallbacks. screencapture(8) is the final
		// fallback (5s ceiling) for the rare case CG also returns nil.
		if semaphore.wait(timeout: .now() + .seconds(3)) == .timedOut {
			task.cancel()
			if let payload = try cgWindowScreenshot(windowId: windowId) {
				return payload
			}
			if let payload = try systemScreenshotWindow(windowId: windowId) {
				return payload
			}
			throw BridgeFailure(message: "Screenshot timed out while capturing window \(windowId)", code: "screenshot_timeout")
		}

		if let error = capturedError.value {
			if let payload = try cgWindowScreenshot(windowId: windowId) {
				return payload
			}
			if let payload = try systemScreenshotWindow(windowId: windowId) {
				return payload
			}
			if let failure = error as? BridgeFailure {
				throw failure
			}
			throw BridgeFailure(message: "Screenshot failed: \(error.localizedDescription)", code: "screenshot_failed")
		}

		guard let image = capturedImage.value else {
			if let payload = try cgWindowScreenshot(windowId: windowId) {
				return payload
			}
			if let payload = try systemScreenshotWindow(windowId: windowId) {
				return payload
			}
			throw BridgeFailure(message: "Screenshot failed", code: "screenshot_failed")
		}

		return try screenshotPayload(image: image, windowId: windowId)
	}

	// Cap on the longest image edge before encoding. Vertex AI rejects
	// many-image requests when any one image exceeds 2576 px/side (observed
	// empirically: "image dimensions exceed max allowed size for many-image
	// requests: 2576 pixels"). Anthropic publishes a 1568 recommendation but
	// it appears to be advisory, not a hard cap - sticking with the observed
	// hard limit until we confirm 1568 is actually enforced. The model still
	// gets exact window-point coords from the envelope; the image is a
	// fallback aid.
	private static let maxImageEdgePixels: Int = 2576

	// JPEG quality for screenshot encoding. UTM/Chrome/full-window
	// screenshots routinely come out at 2.5MB as PNG; the same image
	// at JPEG q75 lands around 320KB - 8x smaller. Vertex's 30MB
	// per-request cap was hitting around 8 PNG screenshots into a
	// long session; q75 gives us closer to 80 before the cap. Quality
	// is plenty for vision-fallback (the agent reads coordinates from
	// the AX envelope, not the image, so we're not penalising any
	// useful precision). PNG is still used for screenshots that
	// require lossless detail in the future via a needsLossless
	// override - none today, but the helper keeps both code paths.
	private static let jpegQuality: Double = 0.75

	private func screenshotPayload(image: CGImage, windowId: UInt32) throws -> [String: Any] {
		// Look up window size BEFORE downscaling so we can normalize the
		// returned image to logical-point resolution. Without windowSize
		// (rare — window vanished between capture and lookup) we fall
		// back to the legacy retina-sized image and the agent does math.
		let windowSize: CGSize? = currentWindowBounds(windowId: windowId)?.size

		// Normalize the captured image to logical-point resolution so
		// 1 image pixel == 1 window logical point. The agent reads pixel
		// coords off the image and passes them as-is to click({x,y}).
		// This is the simpler primitive Codex Computer Use uses (their
		// internal flag is should_normalize_screenshot_to_point_resolution);
		// having two coordinate systems with a mandatory division between
		// them was the source of repeated 'off by N pt' click misses in
		// our extension. With this change there is one coord system.
		//
		// Edge case: if window logical size exceeds the per-edge cap
		// (maxImageEdgePixels = 2576), we can't fit the image at 1:1.
		// In that case we keep the cap and scale falls below 1; envelope
		// text reports the actual scale and the agent divides. Rare for
		// normal app windows on typical retina displays.
		let normalized: CGImage
		if let windowSize, windowSize.width > 0, windowSize.height > 0 {
			let targetW = Int(windowSize.width.rounded())
			let targetH = Int(windowSize.height.rounded())
			let capped = min(max(targetW, targetH), Self.maxImageEdgePixels)
			let longest = max(targetW, targetH)
			if longest > 0 && capped < longest {
				// Window too big for the cap; fall back to capped retina
				// downscale (preserving aspect ratio). scaleFactor will be
				// reported correctly below.
				normalized = downscaleIfNeeded(image)
			} else {
				normalized = resizeImage(image, toWidth: targetW, height: targetH) ?? downscaleIfNeeded(image)
			}
		} else {
			normalized = downscaleIfNeeded(image)
		}

		// Derive the final scale from the actual normalized image vs the
		// window. For the normalized path this should be ~1.0. For the
		// fallback (window > cap, or windowSize lookup failed) it reflects
		// reality (e.g. 0.85 if we hit the cap, or screen backing scale
		// if windowSize is missing).
		var scale: Double = Double(NSScreen.main?.backingScaleFactor ?? 1.0)
		if let windowSize, windowSize.height > 0 {
			let derived = Double(normalized.height) / Double(windowSize.height)
			if derived > 0.05 { scale = derived }
		}

		let rep = NSBitmapImageRep(cgImage: normalized)
		guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: Self.jpegQuality)]) else {
			throw BridgeFailure(message: "Failed to encode screenshot as JPEG", code: "encoding_failed")
		}

		var payload: [String: Any] = [
			// Field name kept as `pngBase64` for backward request-shape
			// compat with older TS callers; payload is JPEG bytes. New
			// `imageMimeType` field tells current callers what to set on
			// the agent message. TS uses imageMimeType when present and
			// falls back to image/png for older helper builds.
			"pngBase64": jpegData.base64EncodedString(),
			"imageMimeType": "image/jpeg",
			"width": normalized.width,
			"height": normalized.height,
			"scaleFactor": scale,
		]
		if let windowSize {
			payload["windowWidth"] = windowSize.width
			payload["windowHeight"] = windowSize.height
		}
		return payload
	}

	/// Resize a CGImage to an exact target pixel size. Used by
	/// screenshotPayload to normalize captures to logical-point
	/// resolution. Returns nil on failure; callers fall back to
	/// downscaleIfNeeded (which preserves aspect and only shrinks past
	/// the per-edge cap).
	private func resizeImage(_ image: CGImage, toWidth newWidth: Int, height newHeight: Int) -> CGImage? {
		guard newWidth > 0, newHeight > 0 else { return nil }
		guard let colorSpace = image.colorSpace else { return nil }
		guard let ctx = CGContext(
			data: nil,
			width: newWidth,
			height: newHeight,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else { return nil }
		ctx.interpolationQuality = .high
		ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
		return ctx.makeImage()
	}

	private func downscaleIfNeeded(_ image: CGImage) -> CGImage {
		let longest = max(image.width, image.height)
		if longest <= Self.maxImageEdgePixels {
			return image
		}
		let ratio = Double(Self.maxImageEdgePixels) / Double(longest)
		let newWidth = max(1, Int((Double(image.width) * ratio).rounded()))
		let newHeight = max(1, Int((Double(image.height) * ratio).rounded()))
		guard let colorSpace = image.colorSpace else { return image }
		guard let ctx = CGContext(
			data: nil,
			width: newWidth,
			height: newHeight,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			return image
		}
		ctx.interpolationQuality = .high
		ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
		return ctx.makeImage() ?? image
	}

	private func cgWindowScreenshot(windowId: UInt32) throws -> [String: Any]? {
		let options: CGWindowListOption = [.optionIncludingWindow]
		let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
		guard let image = CGWindowListCreateImage(.null, options, CGWindowID(windowId), imageOptions) else { return nil }
		guard image.width > 1, image.height > 1 else { return nil }
		return try screenshotPayload(image: image, windowId: windowId)
	}

	private func systemScreenshotWindow(windowId: UInt32) throws -> [String: Any]? {
		let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("pi-cu-\(UUID().uuidString).png")
		defer { try? FileManager.default.removeItem(at: tempUrl) }

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
		process.arguments = ["-x", "-l", String(windowId), tempUrl.path]
		try process.run()
		let deadline = Date().addingTimeInterval(5)
		while process.isRunning && Date() < deadline {
			Thread.sleep(forTimeInterval: 0.05)
		}
		if process.isRunning {
			process.terminate()
			Thread.sleep(forTimeInterval: 0.1)
			if process.isRunning { process.interrupt() }
			return nil
		}
		guard process.terminationStatus == 0 else { return nil }
		guard let data = try? Data(contentsOf: tempUrl), !data.isEmpty else { return nil }
		guard let imageRep = NSBitmapImageRep(data: data), let cgImage = imageRep.cgImage else { return nil }
		return try screenshotPayload(image: cgImage, windowId: windowId)
	}

	private func currentWindowBounds(windowId: UInt32) -> CGRect? {
		if #available(macOS 14.0, *), let scBounds = currentWindowBoundsViaScreenCaptureKit(windowId: windowId) {
			return scBounds
		}

		guard let descriptions = CGWindowListCreateDescriptionFromArray([NSNumber(value: windowId)] as CFArray) as? [[String: Any]],
			let first = descriptions.first,
			let boundsDict = first[kCGWindowBounds as String] as? [String: Any],
			let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
		else {
			return nil
		}
		return bounds
	}

	@available(macOS 14.0, *)
	private func currentWindowBoundsViaScreenCaptureKit(windowId: UInt32) -> CGRect? {
		let semaphore = DispatchSemaphore(value: 0)
		let output = Box<CGRect?>(nil)

		let task = Task {
			defer { semaphore.signal() }
			do {
				if Task.isCancelled {
					return
				}
				let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
				if let window = shareable.windows.first(where: { $0.windowID == windowId }) {
					output.value = window.frame
				}
			} catch {
				output.value = nil
			}
		}

		if semaphore.wait(timeout: .now() + .seconds(2)) == .timedOut {
			task.cancel()
			return nil
		}
		return output.value
	}

	/// Map a window-relative LOGICAL POINT to a global screen point.
	///
	/// Coordinates contract (v3): callers pass `x`, `y` in window-relative
	/// logical points - the same units as `framePoints.w`/`framePoints.h`
	/// returned by `listWindows`. NOT image pixels. On retina displays the
	/// screenshot image is captured at the display's backing scale
	/// (typically 2x), but coordinates are always logical points.
	///
	/// Caller may pass `windowFramePoints: {x,y,w,h}` (logical points) so
	/// we don't need a fresh SCK lookup per click. Falls back to
	/// `currentWindowBounds(windowId)` for backward compat with older TS
	/// callers; that path can be removed once all sites pass the frame.
	///
	/// `captureWidth`/`captureHeight` are accepted but IGNORED in v3 -
	/// they were the proportional-mapping denominator under the old
	/// (broken) image-pixel contract. Kept for request-shape compat.
	private func mapWindowPoint(
		windowId: UInt32,
		x: Double,
		y: Double,
		captureWidth: Double,
		captureHeight: Double,
		windowFrame: CGRect? = nil
	) throws -> CGPoint {
		_ = captureWidth
		_ = captureHeight
		let bounds: CGRect
		if let windowFrame {
			bounds = windowFrame
		} else if let live = currentWindowBounds(windowId: windowId) {
			bounds = live
		} else {
			throw BridgeFailure(message: "Target window is no longer available", code: "window_not_found")
		}

		if x < 0 || y < 0 || x > bounds.size.width || y > bounds.size.height {
			throw BridgeFailure(
				message: "Coordinates (\(Int(x.rounded())),\(Int(y.rounded()))) are outside the window frame (\(Int(bounds.size.width.rounded()))x\(Int(bounds.size.height.rounded())) logical points). Coordinates are window-relative LOGICAL POINTS, not image pixels - on retina displays the screenshot image is ~2x the window's logical size, so divide image-pixel measurements by the scale (see screenshot envelope's capture.scale field) before passing them to click/move_mouse/drag/scroll.",
				code: "coords_out_of_frame"
			)
		}

		let screenX = bounds.origin.x + x
		let screenY = bounds.origin.y + y
		return CGPoint(x: screenX, y: screenY)
	}

	/// Parse an optional `windowFramePoints: {x,y,w,h}` argument from a
	/// request. Returns nil if absent or invalid; callers fall through to
	/// the slower SCK lookup in that case.
	private func windowFrameArg(_ request: [String: Any]) -> CGRect? {
		guard let dict = request["windowFramePoints"] as? [String: Any] else { return nil }
		let x = (dict["x"] as? NSNumber)?.doubleValue ?? 0
		let y = (dict["y"] as? NSNumber)?.doubleValue ?? 0
		let w = (dict["w"] as? NSNumber)?.doubleValue ?? 0
		let h = (dict["h"] as? NSNumber)?.doubleValue ?? 0
		guard w > 0, h > 0 else { return nil }
		return CGRect(x: x, y: y, width: w, height: h)
	}

	/// Deliver a synthesized input event to a target app.
	///
	/// Two paths:
	///   1. **postToPid** — the stealth path. Event enters the target
	///      process's event queue directly. Doesn't change frontmost,
	///      doesn't move keyboard focus, doesn't bleed onto other apps.
	///      Works fine for clicks/keys/moves into Cocoa apps that
	///      dispatch from their own event queue.
	///   2. **cghidEventTap** — the HID path. Event enters at the
	///      bottom of the system event pipeline, gets phase tagging,
	///      passes through the system arbiter, lands on whichever
	///      window is under the cursor. This is how a real mouse or
	///      trackpad delivers input. Apps that grab HID-level input
	///      (VMs like UTM/Parallels/VMware, games, anything using
	///      CGEventTap subscriptions, web-content compositors) only
	///      respond to events that came through this path.
	///
	/// We default to postToPid because it preserves the stealth
	/// contract (input ops never steal focus, never bleed onto non-
	/// target apps). Two upgrade conditions trigger cghidEventTap:
	///
	///   - **Target is frontmost.** Stealth is moot, and HID routing
	///     unlocks HID-grabbing apps (web compositors, games, etc).
	///   - **Target is an opaque-framebuffer app** (UTM, Parallels, etc).
	///     The mac-side process forwards input to its guest via an
	///     internal pipe that only ingests events from the system input
	///     pipeline. postToPid drops the event into the host process's
	///     event queue — the AppKit chrome sees it, but the host→guest
	///     forwarder doesn't. cghidEventTap reaches the forwarder. We
	///     pay the focus-stealth cost (cursor parks at the event
	///     location, just like a real mouse) but the click actually
	///     lands in the guest.
	///
	/// The caller's postMouseMove already parked the system cursor at
	/// the event location, so HID routing lands on the right window.
	///
	/// scrollWheel events bypass this helper entirely and always go
	/// through cghidEventTap (see postScrollWheel) because postToPid
	/// silently no-ops for scroll across the board, frontmost or not.
	private func postEvent(_ event: CGEvent, pid: Int32) {
		if isFrontmost(pid: pid) || isOpaqueFramebufferApp(pid: pid) {
			event.post(tap: .cghidEventTap)
		} else {
			event.postToPid(pid)
		}
	}

	/// Bring an opaque-framebuffer app's window forward so HID-tap
	/// clicks at the cursor location land in IT, not whatever app's
	/// window happens to be on top of the click coordinate.
	///
	/// HID-tap delivery follows the global window stack: the click goes
	/// to the topmost window at the cursor's screen position. For VMs
	/// like UTM, the host process forwards input to the guest only via
	/// HID-tap (postToPid drops at the host->guest boundary), so we MUST
	/// use HID-tap. But if the VM window is behind, say, the user's
	/// terminal, our click hits the terminal instead.
	///
	/// Calling this before input dispatch activates the app and raises
	/// the target window so the HID-tap lands correctly. It's a real
	/// focus change — the user will see their frontmost app jump to the
	/// VM. For opaque-framebuffer apps the stealth contract was already
	/// moot (the agent is going to interact with the guest UI; the user
	/// can't share input with the VM anyway), so we accept that tradeoff
	/// here rather than miss every click.
	///
	/// No-op when the target is already frontmost, when the target isn't
	/// an opaque-framebuffer app, or when the windowId can't be located.
	private func ensureFrontmostForOpaqueFramebuffer(pid: Int32, windowId: UInt32?) {
		guard isOpaqueFramebufferApp(pid: pid) else { return }
		guard !isFrontmost(pid: pid) else { return }
		if let runningApp = NSRunningApplication(processIdentifier: pid) {
			runningApp.activate(options: [])
		}
		if let windowId, let axWindow = axWindowForCGWindow(windowId: windowId, pid: pid) {
			AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
		}
		// Small settle window for the window-server to commit the new
		// frontmost + window stack before we post events.
		usleep(60_000)
	}

	/// Look up the AXUIElement for a given CGWindowID owned by `pid`.
	/// Walks the app's AX window list and matches against CGWindowList
	/// candidates by frame + title — same approach resolveWakeTarget uses.
	private func axWindowForCGWindow(windowId: UInt32, pid: Int32) -> AXUIElement? {
		let appElement = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(appElement, 1.0)
		let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
		let candidates = cgWindowCandidates(pid: pid)
		var usedIds = Set<UInt32>()
		for window in windows {
			let axTitle = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
			let axFrame = frameForWindow(window)
			let candidate = bestCandidate(frame: axFrame, title: axTitle, candidates: candidates, usedIds: usedIds)
			if let candidate { usedIds.insert(candidate.windowId) }
			if candidate?.windowId == windowId {
				return window
			}
		}
		return nil
	}

	/// True when `pid` owns the currently frontmost application. Used
	/// by postEvent to decide between per-PID delivery (stealth) and
	/// HID-tap delivery (compatible with VMs / games / web compositors).
	private func isFrontmost(pid: Int32) -> Bool {
		guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
		return frontmost.processIdentifier == pid
	}

	/// Bundle IDs of apps whose windows are opaque framebuffers
	/// (VM displays, remote-control viewers). These apps do not surface
	/// AX targets for guest content, AND their host→guest input pipes
	/// only ingest cghidEventTap events — postToPid delivery is silently
	/// dropped at the host→guest boundary even though the mac-side
	/// AppKit event queue accepts it.
	///
	/// Keep in sync with `OPAQUE_FRAMEBUFFER_BUNDLE_IDS` in
	/// `src/bridge.ts` (which uses the list for a different purpose:
	/// skipping AX hit-tests in dispatchClick). The two lists overlap
	/// by definition; if they ever diverge we have a bug somewhere.
	private static let opaqueFramebufferBundleIds: Set<String> = [
		"com.utmapp.UTM",
	]

	/// True when `pid` belongs to an opaque-framebuffer app. Returns
	/// false when the pid can't be resolved to a bundle ID (e.g. the
	/// process exited between lookup and check) — we'd rather attempt
	/// stealth delivery in the uncertain case than surprise-steal focus.
	private func isOpaqueFramebufferApp(pid: Int32) -> Bool {
		guard let app = NSRunningApplication(processIdentifier: pid),
			let bundleId = app.bundleIdentifier
		else { return false }
		return Bridge.opaqueFramebufferBundleIds.contains(bundleId)
	}

	private func postMouseMove(to point: CGPoint, pid: Int32) throws {
		guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
			throw BridgeFailure(message: "Failed to create mouse move event", code: "input_failed")
		}
		postEvent(move, pid: pid)
		// Sync the agent overlay cursor. No-op when the overlay is
		// disabled. Single chokepoint: every mouseClick / mouseDrag /
		// scrollWheel goes through here first so we don't need to wire
		// each command site individually. Pass `pid` so the occlusion
		// check knows which app the agent is acting on.
		OverlayController.shared.moveTo(globalPoint: point, ownerPid: pid)
	}

	private func mouseButton(_ name: String) -> CGMouseButton {
		switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "right":
			return .right
		case "middle", "center":
			return .center
		default:
			return .left
		}
	}

	private func mouseDownType(for button: CGMouseButton) -> CGEventType {
		switch button {
		case .right:
			return .rightMouseDown
		case .center:
			return .otherMouseDown
		default:
			return .leftMouseDown
		}
	}

	private func mouseUpType(for button: CGMouseButton) -> CGEventType {
		switch button {
		case .right:
			return .rightMouseUp
		case .center:
			return .otherMouseUp
		default:
			return .leftMouseUp
		}
	}

	private func mouseDraggedType(for button: CGMouseButton) -> CGEventType {
		switch button {
		case .right:
			return .rightMouseDragged
		case .center:
			return .otherMouseDragged
		default:
			return .leftMouseDragged
		}
	}

	private func postMouseClick(at point: CGPoint, pid: Int32, button: CGMouseButton = .left, clickCount: Int = 1) throws {
		try postMouseMove(to: point, pid: pid)
		// Visual: announce the click before posting events so the user
		// sees the ring expand even on extremely fast actions.
		OverlayController.shared.triggerClickRing(
			globalPoint: point,
			button: CursorEffectButton.from(button),
			count: max(1, clickCount),
			ownerPid: pid
		)
		for index in 1...max(1, clickCount) {
			guard let down = CGEvent(mouseEventSource: nil, mouseType: mouseDownType(for: button), mouseCursorPosition: point, mouseButton: button),
				let up = CGEvent(mouseEventSource: nil, mouseType: mouseUpType(for: button), mouseCursorPosition: point, mouseButton: button)
			else {
				throw BridgeFailure(message: "Failed to create mouse click event", code: "input_failed")
			}
			down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
			up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
			postEvent(down, pid: pid)
			usleep(12_000)
			postEvent(up, pid: pid)
			if index < clickCount {
				usleep(70_000)
			}
		}
	}

	private func postMouseDrag(points: [CGPoint], pid: Int32) throws {
		guard points.count >= 2, let first = points.first else {
			throw BridgeFailure(message: "Drag requires at least two points", code: "invalid_args")
		}
		try postMouseMove(to: first, pid: pid)
		guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: first, mouseButton: .left) else {
			throw BridgeFailure(message: "Failed to create mouse down event", code: "input_failed")
		}
		postEvent(down, pid: pid)
		usleep(12_000)

		for point in points.dropFirst() {
			guard let drag = CGEvent(mouseEventSource: nil, mouseType: mouseDraggedType(for: .left), mouseCursorPosition: point, mouseButton: .left) else {
				throw BridgeFailure(message: "Failed to create mouse drag event", code: "input_failed")
			}
			postEvent(drag, pid: pid)
			// Sync overlay to each waypoint as the drag progresses.
			// instant: true bypasses the 180ms tween — with waypoints
			// arriving every 8ms a tweened follow would lag visibly
			// behind the real cursor. The overlay's per-frame render is
			// still rate-limited to 60Hz so we don't redraw on every
			// waypoint, just keep the last sample fresh.
			OverlayController.shared.moveTo(globalPoint: point, ownerPid: pid, instant: true)
			usleep(8_000)
		}

		guard let last = points.last,
			let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: last, mouseButton: .left)
		else {
			throw BridgeFailure(message: "Failed to create mouse up event", code: "input_failed")
		}
		postEvent(up, pid: pid)
	}

	private func postScrollWheel(at point: CGPoint, deltaX: Int, deltaY: Int, pid: Int32) throws {
		try postMouseMove(to: point, pid: pid)
		// Visual: announce the scroll direction + magnitude before
		// posting the event so the user sees the chevrons fan out as
		// the scroll happens. Magnitude→chevron-count mapping lives
		// in OverlayController.triggerScrollEffect.
		OverlayController.shared.triggerScrollEffect(
			globalPoint: point,
			deltaX: deltaX,
			deltaY: deltaY,
			ownerPid: pid
		)
		// We synthesize a 3-phase continuous gesture scroll: began,
		// changed (with the actual delta), ended. Web content (Chrome,
		// Safari) and modern NSScrollView gesture-based scroll
		// handlers filter out events that don't carry phase info -
		// without began/changed/ended bracketing, the web compositor
		// silently drops the scroll. A plain non-continuous wheel
		// event scrolls TextEdit fine but does nothing in Chrome.
		// One bracketed continuous gesture handles both.
		//
		// Scroll-wheel events MUST go through the HID event tap to
		// reach the right window. CGEvent.postToPid silently no-ops
		// for scrolls because NSScrollView's gesture-based scroll
		// handler only listens to events that came through the
		// system HID pipeline. We move the system cursor to the
		// target point first (postMouseMove above), so the
		// HID-tapped scroll lands on the right window via the same
		// hit-test the trackpad would use - without raising or
		// activating the app. Focus stays on whatever window was
		// previously key; the cursor is the only thing that moves,
		// and we already move it for clicks too. Stealth contract
		// preserved.
		let phases: [(phase: Int64, dy: Int32, dx: Int32)] = [
			(1, 0, 0),                                  // kCGScrollPhaseBegan
			(2, Int32(-deltaY), Int32(deltaX)),         // kCGScrollPhaseChanged
			(4, 0, 0),                                  // kCGScrollPhaseEnded
		]
		for (phase, dy, dx) in phases {
			guard let event = CGEvent(
				scrollWheelEvent2Source: nil,
				units: .pixel,
				wheelCount: 2,
				wheel1: dy,
				wheel2: dx,
				wheel3: 0
			) else {
				throw BridgeFailure(message: "Failed to create scroll event", code: "input_failed")
			}
			event.location = point
			event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
			event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
			event.post(tap: .cghidEventTap)
		}
	}

	private func modifierFlag(_ key: String) -> CGEventFlags? {
		switch key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "cmd", "command", "meta", "super", "win", "windows":
			return .maskCommand
		case "ctrl", "control":
			return .maskControl
		case "shift":
			return .maskShift
		case "option", "alt":
			return .maskAlternate
		default:
			return nil
		}
	}

	private func keyCode(_ key: String) -> CGKeyCode? {
		let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let table: [String: CGKeyCode] = [
			"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
			"q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
			"6": 22, "5": 23, "=": 24, "+": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
			"]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
			"l": 37, "j": 38, "'": 39, "\"": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
			"n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, " ": 49, "`": 50, "~": 50,
			"backspace": 51, "delete": 51, "del": 51, "esc": 53, "escape": 53,
			"f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
			"f9": 101, "f10": 109, "f11": 103, "f12": 111,
			"home": 115, "pageup": 116, "page_up": 116, "page down": 121, "pagedown": 121, "page_down": 121,
			"forwarddelete": 117, "forward_delete": 117, "end": 119,
			"left": 123, "arrowleft": 123, "arrow_left": 123,
			"right": 124, "arrowright": 124, "arrow_right": 124,
			"down": 125, "arrowdown": 125, "arrow_down": 125,
			"up": 126, "arrowup": 126, "arrow_up": 126,
		]
		if let code = table[normalized] {
			return code
		}
		// Standalone modifier keys. These also appear in modifierFlag
		// for chord delivery ("Command+L") - this path is for the
		// keypress-as-tap case (open GNOME activities with Super,
		// invoke macOS Spotlight via a Command-only rebind, etc).
		// Super/Meta/Win all alias to the left Command key on macOS,
		// matching the cross-platform convention that calls the OS-
		// modifier 'Super' on Linux and 'Meta' in keyboard event APIs.
		return modifierKeyCode(normalized)
	}

	/// Map a modifier name to the virtual key code of its left-side
	/// physical key. Used by postKey to deliver standalone-modifier
	/// taps (Command alone, Super alone, Shift alone). Returns nil for
	/// non-modifier names.
	private func modifierKeyCode(_ name: String) -> CGKeyCode? {
		switch name {
		case "command", "cmd", "super", "meta", "win", "windows", "lcommand", "leftcommand", "left_command":
			return 55
		case "rcommand", "rightcommand", "right_command":
			return 54
		case "shift", "lshift", "leftshift", "left_shift":
			return 56
		case "rshift", "rightshift", "right_shift":
			return 60
		case "option", "alt", "loption", "leftoption", "left_option", "lalt", "leftalt", "left_alt":
			return 58
		case "roption", "rightoption", "right_option", "ralt", "rightalt", "right_alt":
			return 61
		case "control", "ctrl", "lcontrol", "leftcontrol", "left_control", "lctrl", "leftctrl", "left_ctrl":
			return 59
		case "rcontrol", "rightcontrol", "right_control", "rctrl", "rightctrl", "right_ctrl":
			return 62
		case "fn", "function":
			return 63
		default:
			return nil
		}
	}

	/// Modifier-flag bit corresponding to a modifier virtual key. Used
	/// by postKey to set the right CGEventFlags bit during a standalone
	/// modifier tap so the OS sees a real modifier transition (not just
	/// a bare keyDown of an unflagged virtual key).
	private func modifierFlagForKeyCode(_ code: CGKeyCode) -> CGEventFlags? {
		switch code {
		case 54, 55: return .maskCommand
		case 56, 60: return .maskShift
		case 58, 61: return .maskAlternate
		case 59, 62: return .maskControl
		case 63: return .maskSecondaryFn
		default: return nil
		}
	}

	private func keyChord(_ keys: [String]) -> (flags: CGEventFlags, key: String)? {
		guard keys.count >= 2 else { return nil }
		var flags = CGEventFlags()
		for key in keys.dropLast() {
			guard let flag = modifierFlag(key) else {
				return nil
			}
			flags.insert(flag)
		}
		return (flags, keys.last ?? "")
	}

	private func postKeyPress(keys: [String], pid: Int32) throws {
		if let chord = keyChord(keys) {
			try postKey(chord.key, flags: chord.flags, pid: pid)
			return
		}

		for key in keys {
			let parts = key
				.split(separator: "+")
				.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			if let chord = keyChord(parts) {
				try postKey(chord.key, flags: chord.flags, pid: pid)
			} else {
				try postKey(key, flags: [], pid: pid)
			}
		}
	}

	private func postKey(_ key: String, flags: CGEventFlags, pid: Int32) throws {
		guard let code = keyCode(key) else {
			if key.count == 1 {
				try postUnicodeText(key, pid: pid)
				return
			}
			throw BridgeFailure(message: "Unsupported key '\(key)'", code: "invalid_args")
		}

		// Standalone modifier taps (Command alone, Super alone, Shift
		// alone) need a different event shape: macOS represents modifier
		// transitions as kCGEventFlagsChanged events, NOT keyDown/keyUp.
		// Apps that listen via NSEvent.flagsChanged or via a CGEventTap
		// subscribed to the flagsChanged mask (UTM, Parallels, GNOME's
		// remote input handler, etc) ignore keyDown of modifier virtual
		// keys - they only act on the flag transition. Posting keyDown
		// works for Cocoa apps that hit-test the virtual key directly,
		// but the canonical shape that everything respects is
		// flagsChanged with the modifier bit toggled.
		if let modFlag = modifierFlagForKeyCode(code) {
			try postModifierTap(virtualKey: code, modifierFlag: modFlag, baseFlags: flags, pid: pid)
			return
		}

		guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
			let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
		else {
			throw BridgeFailure(message: "Failed to create key event", code: "input_failed")
		}
		down.flags = flags
		up.flags = flags
		postEvent(down, pid: pid)
		usleep(8_000)
		postEvent(up, pid: pid)
	}

	/// Synthesize a press-and-release of a standalone modifier key
	/// (Command alone, Super alone, Shift alone). Two CGEvents of type
	/// kCGEventFlagsChanged, one with the modifier bit set, one with it
	/// cleared - this is the shape that macOS itself produces when the
	/// user taps a physical modifier, and the only shape that flag-tap
	/// listeners (UTM/Parallels guest input, GNOME activities trigger,
	/// CGEventTap subscribers on flagsChanged) react to.
	private func postModifierTap(virtualKey: CGKeyCode, modifierFlag: CGEventFlags, baseFlags: CGEventFlags, pid: Int32) throws {
		guard let down = CGEvent(source: nil) else {
			throw BridgeFailure(message: "Failed to create modifier event", code: "input_failed")
		}
		down.type = .flagsChanged
		down.setIntegerValueField(.keyboardEventKeycode, value: Int64(virtualKey))
		down.flags = baseFlags.union(modifierFlag)

		guard let up = CGEvent(source: nil) else {
			throw BridgeFailure(message: "Failed to create modifier event", code: "input_failed")
		}
		up.type = .flagsChanged
		up.setIntegerValueField(.keyboardEventKeycode, value: Int64(virtualKey))
		up.flags = baseFlags

		postEvent(down, pid: pid)
		usleep(8_000)
		postEvent(up, pid: pid)
	}

	private func postUnicodeText(_ text: String, pid: Int32) throws {
		for scalar in text.unicodeScalars {
			let char = String(scalar)
			guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
				let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
			else {
				throw BridgeFailure(message: "Failed to create unicode key event", code: "input_failed")
			}
			setUnicodeString(event: down, text: char)
			setUnicodeString(event: up, text: char)
			postEvent(down, pid: pid)
			usleep(8_000)
			postEvent(up, pid: pid)
		}
	}

	private func setUnicodeString(event: CGEvent, text: String) {
		var utf16 = Array(text.utf16)
		utf16.withUnsafeMutableBufferPointer { buffer in
			guard let base = buffer.baseAddress else { return }
			event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
		}
	}

}

_ = NSApplication.shared
// Stay invisible by default. The overlay subsystem flips this to
// `.accessory` lazily on the first overlay.enable request so users who
// never enable the overlay see zero behavior change vs the prior
// `.prohibited` helper.
NSApp.setActivationPolicy(.prohibited)

let bridge = Bridge()
bridge.start()
NSApplication.shared.run()
