import Foundation
func simulate(_ response: Double, _ zeta: Double) -> (Double, Double, Double, Double) {
  let k = pow(2 * .pi / response, 2), c = 4 * .pi * zeta / response
  var x = 0.0, v = 0.0, t = 0.0, peak = 0.0, peakT = 0.0, at93 = -1.0, rest = 0.0
  while t < 1 {
    let f = -k * (x - 1) - c * v; v += f / 4800; x += v / 4800; t += 1.0 / 4800
    if x > peak { peak = x; peakT = t }
    if at93 < 0 && x >= 0.93 { at93 = t }
    if abs(x - 1) > 0.004 { rest = t }
  }
  return (peak - 1, peakT, at93, rest)
}
let travel = 279.0
var best: (Double, Double, Double) = (0, 0, 1e9)
for r in stride(from: 0.10, through: 0.25, by: 0.005) {
  for z in stride(from: 0.70, through: 0.95, by: 0.005) {
    let (o, pt, a, rest) = simulate(r, z)
    let err = pow((o * travel - 3.5) / 1.0, 2) + pow((a - 0.066) / 0.008, 2) + pow((pt - 0.12) / 0.02, 2) + pow((rest - 0.22) / 0.04, 2)
    if err < best.2 { best = (r, z, err) }
  }
}
let (o, pt, a, rest) = simulate(best.0, best.1)
print(String(format: "best response %.3f damping %.3f: overshoot %.1f pt at %.3f s, 93%% in %.0f ms, rest %.2f s", best.0, best.1, o * travel, pt, a * 1000, rest))
