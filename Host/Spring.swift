import AppKit
import QuartzCore

final class Spring: NSObject {
  private(set) var value: CGFloat
  private(set) var target: CGFloat
  private var velocity: CGFloat = 0
  private var stiffness: CGFloat
  private var damping: CGFloat
  private var link: CADisplayLink?
  private var lastTime: CFTimeInterval = 0
  private let apply: (CGFloat) -> Void

  init(value: CGFloat, response: CGFloat, dampingRatio: CGFloat, apply: @escaping (CGFloat) -> Void) {
    self.value = value
    target = value
    stiffness = pow(2 * .pi / response, 2)
    damping = 4 * .pi * dampingRatio / response
    self.apply = apply
  }

  var isMoving: Bool { link != nil }

  func configure(response: CGFloat, dampingRatio: CGFloat) {
    stiffness = pow(2 * .pi / response, 2)
    damping = 4 * .pi * dampingRatio / response
  }

  func animate(to newTarget: CGFloat, in view: NSView) {
    target = newTarget
    guard link == nil else { return }
    if abs(value - target) < 0.0005 { return }
    let link = view.displayLink(target: self, selector: #selector(step(_:)))
    lastTime = 0
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func jump(to newTarget: CGFloat) {
    link?.invalidate()
    link = nil
    target = newTarget
    value = newTarget
    velocity = 0
    apply(value)
  }

  @objc private func step(_ link: CADisplayLink) {
    let now = link.targetTimestamp
    var remaining = lastTime == 0 ? 1.0 / 120 : min(now - lastTime, 1.0 / 30)
    lastTime = now
    let substep = 1.0 / 480
    while remaining > 0 {
      let dt = CGFloat(min(substep, remaining))
      let force = -stiffness * (value - target) - damping * velocity
      velocity += force * dt
      value += velocity * dt
      remaining -= Double(dt)
    }
    if abs(value - target) < 0.0005 && abs(velocity) < 0.01 {
      value = target
      velocity = 0
      link.invalidate()
      self.link = nil
    }
    apply(value)
  }
}
