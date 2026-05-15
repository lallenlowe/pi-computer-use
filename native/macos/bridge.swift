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

final class InputSuppressionGuard {
	private let lock = NSLock()
	private var eventTap: CFMachPort?
	private var eventTapSource: CFRunLoopSource?
	private var tapRunLoop: CFRunLoop?
	private var tapThread: Thread?

	func begin() throws {
		lock.lock()
		if eventTap != nil {
			lock.unlock()
			return
		}
		lock.unlock()

		let eventTypes: [CGEventType] = [
			.keyDown,
			.keyUp,
			.flagsChanged,
			.leftMouseDown,
			.leftMouseUp,
			.rightMouseDown,
			.rightMouseUp,
			.otherMouseDown,
			.otherMouseUp,
			.mouseMoved,
			.leftMouseDragged,
			.rightMouseDragged,
			.otherMouseDragged,
			.scrollWheel,
			.tabletPointer,
			.tabletProximity,
		]
		let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
			partial | (CGEventMask(1) << CGEventMask(type.rawValue))
		}

		let callback: CGEventTapCallBack = { _proxy, type, event, userInfo in
			guard let userInfo else { return Unmanaged.passUnretained(event) }
			let inputGuard = Unmanaged<InputSuppressionGuard>.fromOpaque(userInfo).takeUnretainedValue()
			if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
				inputGuard.reenableTap()
				return Unmanaged.passUnretained(event)
			}
			return nil
		}

		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: mask,
			callback: callback,
			userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
		) else {
			throw BridgeFailure(message: "Failed to create input suppression event tap", code: "input_suppression_unavailable")
		}

		lock.lock()
		eventTap = tap
		lock.unlock()
		let thread = Thread { [weak self] in
			guard let self else { return }
			let runLoop = CFRunLoopGetCurrent()
			self.lock.lock()
			self.tapRunLoop = runLoop
			self.eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
			if let source = self.eventTapSource {
				CFRunLoopAddSource(runLoop, source, .commonModes)
			}
			CGEvent.tapEnable(tap: tap, enable: true)
			self.lock.unlock()
			CFRunLoopRun()
		}
		thread.name = "pi-computer-use-input-suppression"
		lock.lock()
		tapThread = thread
		lock.unlock()
		thread.start()

		let deadline = Date().addingTimeInterval(1.0)
		while tapRunLoop == nil && Date() < deadline {
			Thread.sleep(forTimeInterval: 0.01)
		}
		if tapRunLoop == nil {
			throw BridgeFailure(message: "Timed out starting input suppression", code: "input_suppression_timeout")
		}
	}

	func end() {
		lock.lock()
		let tap = eventTap
		let source = eventTapSource
		let runLoop = tapRunLoop
		eventTap = nil
		eventTapSource = nil
		tapRunLoop = nil
		tapThread = nil
		lock.unlock()

		if let tap {
			CGEvent.tapEnable(tap: tap, enable: false)
		}
		if let source, let runLoop {
			CFRunLoopRemoveSource(runLoop, source, .commonModes)
			CFRunLoopStop(runLoop)
		}
	}

	func reenableTap() {
		lock.lock()
		let tap = eventTap
		lock.unlock()
		if let tap {
			CGEvent.tapEnable(tap: tap, enable: true)
		}
	}

}

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
	static let duration: CFTimeInterval = 0.350

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
	static let duration: CFTimeInterval = 0.650

	func isFinished(at now: CFTimeInterval) -> Bool {
		return now - startTime >= TypeFlashEffect.duration
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
	var clickRings: [ScreenLocalClickRing] = []
	var typeFlashes: [ScreenLocalTypeFlash] = []

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
		drawTypeFlashes(ctx)
		drawClickRings(ctx)

		guard let point = cursorPoint else { return }

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
	/// rectangle outline whose alpha follows a 100ms-in / 250ms-hold /
	/// 300ms-out envelope.
	private func drawTypeFlashes(_ ctx: CGContext) {
		for flash in typeFlashes {
			let t = max(0.0, min(1.0, flash.age / TypeFlashEffect.duration))
			// Envelope: fade in over first ~15%, hold to 55%, fade out
			// over the final 45%. Numbers chosen so the user gets a clear
			// "thing happened here" impression without it lingering.
			let alpha: CGFloat
			if t < 0.15 {
				alpha = CGFloat(t / 0.15)
			} else if t < 0.55 {
				alpha = 1.0
			} else {
				alpha = CGFloat((1.0 - t) / 0.45)
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
/// cmd-tab, so it remains stealthy.
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
	private var displayTimer: Timer? = nil
	private var screenChangeObserver: NSObjectProtocol? = nil

	// Animation tunables. Settable from the bridge so the TS-side
	// config can drive them; defaults match a quick, restrained motion.
	var animationStyle: OverlayAnimationStyle = .arc
	var animationDuration: CFTimeInterval = 0.180

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
	func moveTo(globalPoint: CGPoint) {
		lastGlobalPoint = globalPoint
		if !enabled { return }

		// If we have no prior position or animation is off, just snap.
		guard animationStyle != .off, let from = currentDisplayedGlobalPoint else {
			cancelAnimation()
			renderGlobalPoint(globalPoint)
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
	func triggerClickRing(globalPoint: CGPoint, button: CursorEffectButton, count: Int = 1) {
		if !enabled { return }
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
	func triggerTypeFlash(globalRect: CGRect?) {
		if !enabled { return }
		let now = CACurrentMediaTime()
		typeFlashes.append(TypeFlashEffect(
			id: UUID(),
			globalRect: globalRect,
			fallbackCursorPoint: globalRect == nil ? lastGlobalPoint : nil,
			startTime: now
		))
		ensureDisplayTimer()
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
		// Don't kill the timer if effects still need ticking. The timer
		// shutdown logic in `tick` checks both animation + effects so a
		// click-ring fired right before the cursor finishes its tween
		// keeps animating to completion.
		if !hasActiveEffects() {
			displayTimer?.invalidate()
			displayTimer = nil
		}
	}

	private func hasActiveEffects() -> Bool {
		return !clickRings.isEmpty || !typeFlashes.isEmpty
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

		// Repaint with whatever cursor + effects are current.
		let pointToRender = currentDisplayedGlobalPoint ?? lastGlobalPoint
		if let pointToRender = pointToRender {
			renderGlobalPoint(pointToRender, now: now)
		} else {
			renderEmpty(now: now)
		}

		if animation == nil && !hasActiveEffects() {
			displayTimer?.invalidate()
			displayTimer = nil
		}
	}

/// Paint the cursor at a specific global screen point across all
	/// per-screen overlay windows, plus any active effects projected
	/// into screen-local coords. No state change - callers update
	/// `currentDisplayedGlobalPoint` themselves.
	private func renderGlobalPoint(_ globalPoint: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) {
		for (index, window) in windows.enumerated() {
			let screen = window.screen ?? NSScreen.screens[index]
			let local = convertGlobalToScreenLocal(globalPoint, screen: screen)
			let view = views[index]
			if NSPointInRect(NSPoint(x: local.x, y: local.y), screen.frame.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)) {
				view.cursorPoint = local
			} else {
				view.cursorPoint = nil
			}
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
			view.needsDisplay = true
		}
	}

	/// Repaint with no cursor (e.g. effects-only state). Lets a
	/// type-flash fire even when we've never tracked a cursor point.
	private func renderEmpty(now: CFTimeInterval) {
		for (index, window) in windows.enumerated() {
			let screen = window.screen ?? NSScreen.screens[index]
			let view = views[index]
			view.cursorPoint = nil
			view.clickRings = clickRings.map { ring in
				let local = convertGlobalToScreenLocal(ring.globalPoint, screen: screen)
				return ScreenLocalClickRing(localPoint: local, button: ring.button, age: now - ring.startTime)
			}
			view.typeFlashes = typeFlashes.compactMap { flash in
				guard let g = flash.globalRect else { return nil }
				return ScreenLocalTypeFlash(localRect: convertGlobalRectToScreenLocal(g, screen: screen), age: now - flash.startTime)
			}
			view.needsDisplay = true
		}
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
	private let inputSuppressionGuard = InputSuppressionGuard()
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
		case "getFrontmost":
			return try getFrontmost()
		case "getUserContext":
			return try getUserContext()
		case "beginInputSuppression":
			return try beginInputSuppression()
		case "endInputSuppression":
			return endInputSuppression()
		case "restoreUserFocus":
			return try restoreUserFocus(request)
		case "focusWindow":
			return try focusWindow(request)
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
			OverlayController.shared.moveTo(globalPoint: CGPoint(x: x, y: y))
			return ["moved": OverlayController.shared.isEnabled()]
		case "overlayClickEffect":
			let x = try doubleArg(request, "x")
			let y = try doubleArg(request, "y")
			let button = CursorEffectButton(rawValue: optionalStringArg(request, "button")?.lowercased() ?? "left") ?? .left
			let count = optionalIntArg(request, "count") ?? 1
			OverlayController.shared.triggerClickRing(globalPoint: CGPoint(x: x, y: y), button: button, count: count)
			return ["triggered": OverlayController.shared.isEnabled()]
		case "overlayTypeEffect":
			let x = try? doubleArg(request, "x")
			let y = try? doubleArg(request, "y")
			let w = try? doubleArg(request, "w")
			let h = try? doubleArg(request, "h")
			var rect: CGRect? = nil
			if let x = x, let y = y, let w = w, let h = h, w > 0, h > 0 {
				rect = CGRect(x: x, y: y, width: w, height: h)
			}
			OverlayController.shared.triggerTypeFlash(globalRect: rect)
			return ["triggered": OverlayController.shared.isEnabled()]
		case "overlayConfigure":
			if let style = optionalStringArg(request, "style") {
				OverlayController.shared.animationStyle = OverlayAnimationStyle(style)
			}
			if let durationMs = (request["durationMs"] as? NSNumber)?.doubleValue, durationMs >= 0 {
				OverlayController.shared.animationDuration = max(0.0, durationMs / 1000.0)
			}
			return [
				"style": OverlayController.shared.animationStyle.rawValue,
				"durationMs": Int(OverlayController.shared.animationDuration * 1000),
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

	private func beginInputSuppression() throws -> [String: Any] {
		try inputSuppressionGuard.begin()
		return ["active": true]
	}

	private func endInputSuppression() -> [String: Any] {
		inputSuppressionGuard.end()
		return ["active": false]
	}

	private func restoreUserFocus(_ request: [String: Any]) throws -> [String: Any] {
		let pid = Int32(try intArg(request, "pid"))
		let targetTitle = optionalStringArg(request, "windowTitle")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard let app = NSRunningApplication(processIdentifier: pid) else {
			throw BridgeFailure(message: "App with pid \(pid) is no longer running", code: "app_not_found")
		}

		let appRestored = app.activate()
		var restoredWindowTitle = ""
		var windowRestored = false

		if !targetTitle.isEmpty {
			let appElement = AXUIElementCreateApplication(pid)
			let windows = axElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
			let normalizedTarget = targetTitle.lowercased()
			if let match = windows.first(where: {
				(stringAttribute($0, attribute: kAXTitleAttribute as CFString) ?? "")
					.trimmingCharacters(in: .whitespacesAndNewlines)
					.lowercased() == normalizedTarget
			}) {
				restoredWindowTitle = stringAttribute(match, attribute: kAXTitleAttribute as CFString) ?? ""
				let setMainStatus = AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
				let setFocusedStatus = AXUIElementSetAttributeValue(match, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				let raiseStatus = AXUIElementPerformAction(match, kAXRaiseAction as CFString)
				windowRestored = setMainStatus == .success || setFocusedStatus == .success || raiseStatus == .success
			}
		}

		return [
			"restored": appRestored || windowRestored,
			"appRestored": appRestored,
			"windowRestored": windowRestored,
			"appName": app.localizedName ?? "Unknown App",
			"windowTitle": restoredWindowTitle,
		]
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
		return [
			"ok": positionStatus == .success || sizeStatus == .success,
			"positionStatus": Int(positionStatus.rawValue),
			"sizeStatus": Int(sizeStatus.rawValue),
			"framePoints": ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height],
		]
	}

	private func focusWindow(_ request: [String: Any]) throws -> [String: Any] {
		let pid = Int32(try intArg(request, "pid"))
		let windowId = optionalIntArg(request, "windowId").map { UInt32($0) }
		let windowRef = optionalStringArg(request, "windowRef")
		guard let window = windowElement(pid: pid, windowId: windowId, windowRef: windowRef) else {
			return ["focused": false, "reason": "window_not_found"]
		}

		let appElement = AXUIElementCreateApplication(pid)
		if let focusedWindow = copyAttribute(appElement, attribute: kAXFocusedWindowAttribute as CFString).flatMap(asAXElement),
			sameElement(focusedWindow, window)
		{
			return ["focused": true, "alreadyFocused": true]
		}

		let setMainStatus = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
		let setFocusedStatus = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
		let raiseStatus = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
		let focused = setMainStatus == .success || setFocusedStatus == .success || raiseStatus == .success
		var result: [String: Any] = [
			"focused": focused,
			"setMain": setMainStatus == .success,
			"setFocused": setFocusedStatus == .success,
			"raised": raiseStatus == .success,
		]
		if !focused {
			result["reason"] = "focus_failed"
		}
		return result
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

		var output: [[String: Any]] = []
		for window in windows {
			let axTitle = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? ""
			let axFrame = frameForWindow(window)
			let candidate = bestCandidate(frame: axFrame, title: axTitle, candidates: candidates, usedIds: usedIds)
			if let candidate {
				usedIds.insert(candidate.windowId)
			}

			let effectiveFrame = axFrame.width > 1 && axFrame.height > 1 ? axFrame : (candidate?.bounds ?? axFrame)
			if effectiveFrame.width < 100 || effectiveFrame.height < 80 { continue }
			let hasUsableAXFrame = axFrame.width > 1 && axFrame.height > 1
			let title = hasUsableAXFrame && !axTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? axTitle : (candidate?.title.isEmpty == false ? candidate!.title : axTitle)
			let windowRef = refStore.storeWindow(window)
			let isMinimized = boolAttribute(window, attribute: kAXMinimizedAttribute as CFString) ?? false
			let isMain = boolAttribute(window, attribute: kAXMainAttribute as CFString) ?? false
			let isFocused = boolAttribute(window, attribute: kAXFocusedAttribute as CFString) ?? false
			let scale = displayScaleFactor(for: effectiveFrame)

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
				"isOnscreen": candidate?.isOnscreen ?? !isMinimized,
				"isMain": isMain,
				"isFocused": isFocused,
			]
			if let candidate {
				item["windowId"] = Int(candidate.windowId)
			}
			output.append(item)
		}
		return output
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
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight)
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
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight)
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
		let points = try rawPath.map { rawPoint -> CGPoint in
			guard let x = (rawPoint["x"] as? NSNumber)?.doubleValue,
				let y = (rawPoint["y"] as? NSNumber)?.doubleValue
			else {
				throw BridgeFailure(message: "mouseDrag path entries must include numeric x and y", code: "invalid_args")
			}
			return try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight)
		}
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
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight)
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
		try postKeyPress(keys: keys, pid: targetPid)
		return ["pressed": true]
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

		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight)
		OverlayController.shared.moveTo(globalPoint: point)
		OverlayController.shared.triggerClickRing(globalPoint: point, button: .left)
		guard let hitElement = hitTestElement(at: point) else {
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
				// Score with a high baseline — a stealth-only model needs the composer
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
		syncOverlayToElement(element)
		if let frame = frameForElement(element) {
			OverlayController.shared.triggerClickRing(globalPoint: CGPoint(x: frame.midX, y: frame.midY), button: .left)
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
		syncOverlayToElement(element)
		if let frame = frameForElement(element) {
			OverlayController.shared.triggerClickRing(globalPoint: CGPoint(x: frame.midX, y: frame.midY), button: .left)
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
		syncOverlayToElement(element)
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

		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight)
		OverlayController.shared.moveTo(globalPoint: point)
		guard let hitElement = hitTestElement(at: point) else {
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
		syncOverlayToElement(element)
		return performScrollActionOrAncestor(startingAt: element, targetPid: targetPid, scrollX: optionalIntArg(request, "scrollX") ?? 0, scrollY: optionalIntArg(request, "scrollY") ?? 0, steps: max(1, min(8, optionalIntArg(request, "steps") ?? 1)))
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
		let point = try mapWindowPoint(windowId: windowId, x: x, y: y, captureWidth: captureWidth, captureHeight: captureHeight)
		OverlayController.shared.moveTo(globalPoint: point)
		guard let hitElement = hitTestElement(at: point) else {
			return ["scrolled": false, "reason": "hit_test_failed"]
		}
		return performScrollActionOrAncestor(startingAt: hitElement, targetPid: targetPid, scrollX: optionalIntArg(request, "scrollX") ?? 0, scrollY: optionalIntArg(request, "scrollY") ?? 0, steps: max(1, min(8, optionalIntArg(request, "steps") ?? 1)))
	}

	/// Move the overlay cursor to the visual center of an AX element if
	/// the element exposes a frame. Used by `*Element` AX commands so
	/// click({ ref }) animates the cursor to the right place even when
	/// no raw coordinate was supplied.
	private func syncOverlayToElement(_ element: AXUIElement) {
		guard let frame = frameForElement(element) else { return }
		let center = CGPoint(x: frame.midX, y: frame.midY)
		OverlayController.shared.moveTo(globalPoint: center)
	}

	private func hitTestElement(at point: CGPoint) -> AXUIElement? {
		let systemWide = AXUIElementCreateSystemWide()
		var hitElement: AXUIElement?
		let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitElement)
		guard status == .success, let hitElement else { return nil }
		return hitElement
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
		// Visual: outline the field that was just populated.
		OverlayController.shared.triggerTypeFlash(globalRect: frameForElement(element))
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
		OverlayController.shared.triggerTypeFlash(globalRect: focusedRect)
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
			let isOnscreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
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

				let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
				capturedImage.value = image
			} catch {
				capturedError.value = error
			}
		}

		if semaphore.wait(timeout: .now() + .seconds(8)) == .timedOut {
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

	private func screenshotPayload(image: CGImage, windowId: UInt32) throws -> [String: Any] {
		guard let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
			throw BridgeFailure(message: "Failed to encode screenshot as PNG", code: "encoding_failed")
		}

		let bounds = currentWindowBounds(windowId: windowId)
		let scale = bounds.map { displayScaleFactor(for: $0) } ?? 1.0

		return [
			"pngBase64": pngData.base64EncodedString(),
			"width": image.width,
			"height": image.height,
			"scaleFactor": scale,
		]
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

	private func mapWindowPoint(
		windowId: UInt32,
		x: Double,
		y: Double,
		captureWidth: Double,
		captureHeight: Double
	) throws -> CGPoint {
		guard let bounds = currentWindowBounds(windowId: windowId) else {
			throw BridgeFailure(message: "Target window is no longer available", code: "window_not_found")
		}

		let relX = min(max(x / captureWidth, 0), 1)
		let relY = min(max(y / captureHeight, 0), 1)
		let screenX = bounds.origin.x + bounds.size.width * relX
		let screenY = bounds.origin.y + bounds.size.height * relY
		return CGPoint(x: screenX, y: screenY)
	}

	private func postEvent(_ event: CGEvent, pid: Int32) {
		event.postToPid(pid)
	}

	private func postMouseMove(to point: CGPoint, pid: Int32) throws {
		guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
			throw BridgeFailure(message: "Failed to create mouse move event", code: "input_failed")
		}
		postEvent(move, pid: pid)
		// Sync the agent overlay cursor. No-op when the overlay is
		// disabled. Single chokepoint: every mouseClick / mouseDrag /
		// scrollWheel goes through here first so we don't need to wire
		// each command site individually.
		OverlayController.shared.moveTo(globalPoint: point)
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
			count: max(1, clickCount)
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
		guard let event = CGEvent(
			scrollWheelEvent2Source: nil,
			units: .pixel,
			wheelCount: 2,
			wheel1: Int32(-deltaY),
			wheel2: Int32(deltaX),
			wheel3: 0
		) else {
			throw BridgeFailure(message: "Failed to create scroll event", code: "input_failed")
		}
		event.location = point
		postEvent(event, pid: pid)
	}

	private func modifierFlag(_ key: String) -> CGEventFlags? {
		switch key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "cmd", "command", "meta":
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
		return table[normalized]
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
