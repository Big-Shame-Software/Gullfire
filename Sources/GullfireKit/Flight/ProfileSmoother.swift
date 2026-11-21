import Foundation

/// Curvature-limited, raise-only smoothing of an altitude profile (Spikes/LEVELING_PLAN.md). The autopilot's feedforward
/// tracks a route's altitude exactly, so every sharp corner of the profile (flat to ramp, ramp to flat) becomes a vertical
/// jolt. This rounds the corners so that the second difference at each sample is within what an aircraft flying the profile
/// at its own speed can ask of its vertical acceleration. Rounding never lowers the profile: the checker and the avoidance
/// clearances were computed on it.
public enum ProfileSmoother {
    public struct Settings: Sendable {
        /// m/s2 the profile may ask of an aircraft flying it at its own speed.
        public var maxVerticalAcceleration = 1.5
        /// m/s, floor for the speed used.
        public var minSpeed = 15.0
        /// The plan's climb and descent gradient (rise over run).
        public var gradient = 0.8 * tan(20 * Double.pi / 180)
        /// Safety bound on the Newton steps.
        public var iterations = 400

        public init() {}
    }

    /// One linear inequality, `coef . r[idx] - rhs <= 0`, with at most three terms.
    struct Row {
        var idx: [Int]
        var coef: [Double]
        var rhs: Double

        func residual(_ r: [Double]) -> Double {
            var s = -rhs
            for k in idx.indices { s += coef[k] * r[idx[k]] }
            return s
        }
    }

    /// Altitude per sample (closed loop, `spacing` metres apart), raised (never lowered) so that the second difference at
    /// each sample is within `maxVerticalAcceleration * spacing^2 / max(speed, minSpeed)^2` metres, and the gradient between
    /// consecutive samples is within `gradient * spacing`. Pure: same inputs, same output.
    ///
    /// The three limits and the floor (the input altitude) are linear constraints on the profile. The profile is the least-squares
    /// style projection of the input onto them, found by damped Newton steps on the sum of squared violations. The steps are
    /// solved by conjugate gradients, because the constraint matrix is banded and sparse. A profile that already meets the
    /// limits is a fixed point. (A Gauss-Seidel sweep that raises each sample's neighbours instead does not converge: a
    /// curvature error at a crest moves to the next sample and never dies out.)
    public static func smooth(altitudes: [Double], speeds: [Double], spacing: Double, settings: Settings = Settings()) -> [Double] {
        let n = altitudes.count
        guard n >= 3, speeds.count == n, spacing > 0 else { return altitudes }
        let step = settings.gradient * spacing
        var rows: [Row] = []
        rows.reserveCapacity(5 * n)
        for j in 0..<n {
            let p = (j - 1 + n) % n, q = (j + 1) % n
            let s = max(speeds[j], settings.minSpeed)
            let d = settings.maxVerticalAcceleration * spacing * spacing / (s * s)
            // c_j = r[p] + r[q] - 2 r[j] must lie within [-d, d].
            rows.append(Row(idx: [p, j, q], coef: [1, -2, 1], rhs: d))
            rows.append(Row(idx: [p, j, q], coef: [-1, 2, -1], rhs: d))
        }
        for k in 0..<n {
            let q = (k + 1) % n
            // The step from sample k to k+1 is within the gradient limit, both ways.
            rows.append(Row(idx: [k, q], coef: [-1, 1], rhs: step))
            rows.append(Row(idx: [k, q], coef: [1, -1], rhs: step))
        }
        for i in 0..<n {
            // Raise only: r[i] >= altitudes[i].
            rows.append(Row(idx: [i], coef: [-1], rhs: -altitudes[i]))
        }

        var r = altitudes
        minimiseViolations(&r, rows: rows, iterations: settings.iterations)
        // The solver stops at a tolerance, so clamp the floor exactly.
        for i in 0..<n where r[i] < altitudes[i] {
            r[i] = altitudes[i]
        }
        return r
    }

    /// Sum of squared violations: each row contributes max(0, residual)^2.
    static func penalty(_ rows: [Row], _ r: [Double]) -> Double {
        var total = 0.0
        for row in rows {
            let v = row.residual(r)
            if v > 0 { total += v * v }
        }
        return total
    }

    /// Damped Newton on the penalty. Each step solves H d = -g over the violated rows, with H = 2 sum a a^T, by conjugate
    /// gradients, then backtracks until the penalty falls (Armijo condition). Stops when nothing is violated, or when a step
    /// cannot lower the penalty.
    static func minimiseViolations(_ r: inout [Double], rows: [Row], iterations: Int) {
        let n = r.count
        for _ in 0..<iterations {
            var active: [Row] = []
            var g = [Double](repeating: 0, count: n)
            var current = 0.0
            for row in rows {
                let v = row.residual(r)
                guard v > 0 else { continue }
                active.append(row)
                current += v * v
                for k in row.idx.indices { g[row.idx[k]] += 2 * v * row.coef[k] }
            }
            if active.isEmpty { return }
            let gnorm = g.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if gnorm < 1e-12 { return }

            let x = solveNewton(g: g, active: active, n: n)
            let slope = zip(g, x).reduce(0) { $0 + $1.0 * $1.1 }
            guard slope < 0 else { return }

            var t = 1.0
            var accepted = false
            for _ in 0..<60 {
                let trial = (0..<n).map { r[$0] + t * x[$0] }
                let p = penalty(rows, trial)
                if p <= current + 1e-4 * t * slope || p < 1e-20 {
                    r = trial
                    accepted = true
                    break
                }
                t *= 0.5
            }
            if !accepted { return }
        }
    }

    /// Solves (2 sum a a^T + ridge) x = -g. Preconditioned conjugate gradients, where the preconditioner is the exact banded
    /// factorisation of the rows that do not wrap round the loop. Only the few rows that wrap (the first and last samples)
    /// are left out of it, so the preconditioned system is the identity plus a low-rank term and converges in a few steps.
    static func solveNewton(g: [Double], active: [Row], n: Int) -> [Double] {
        let ridge = 1e-9
        // Banded part: entry (i, j) with |i - j| <= 2 is stored at band[5 i + (j - i + 2)].
        var band = [Double](repeating: 0, count: 5 * n)
        var wrapping: [Row] = []
        for row in active {
            let lo = row.idx.min() ?? 0, hi = row.idx.max() ?? 0
            guard hi - lo <= 2 else {
                wrapping.append(row)
                continue
            }
            for u in row.idx.indices {
                for v in row.idx.indices {
                    band[5 * row.idx[u] + (row.idx[v] - row.idx[u] + 2)] += 2 * row.coef[u] * row.coef[v]
                }
            }
        }
        for i in 0..<n { band[5 * i + 2] += ridge }
        let factor = bandedFactor(band, n: n)

        func hessianTimes(_ v: [Double]) -> [Double] {
            var out = v.map { ridge * $0 }
            for row in active {
                var av = 0.0
                for k in row.idx.indices { av += row.coef[k] * v[row.idx[k]] }
                for k in row.idx.indices { out[row.idx[k]] += 2 * row.coef[k] * av }
            }
            return out
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for i in a.indices { s += a[i] * b[i] }
            return s
        }

        let gnorm = dot(g, g).squareRoot()
        var x = [Double](repeating: 0, count: n)
        guard gnorm > 0 else { return x }
        var r = g.map { -$0 }
        var z = bandedSolve(factor, r, n: n)
        var p = z
        var rz = dot(r, z)
        for _ in 0..<(4 * wrapping.count + 60) {
            let hp = hessianTimes(p)
            let php = dot(p, hp)
            guard php > 0 else { break }
            let alpha = rz / php
            for i in 0..<n {
                x[i] += alpha * p[i]
                r[i] -= alpha * hp[i]
            }
            if dot(r, r).squareRoot() <= 1e-10 * gnorm { break }
            z = bandedSolve(factor, r, n: n)
            let rzNew = dot(r, z)
            let beta = rzNew / rz
            for i in 0..<n { p[i] = z[i] + beta * p[i] }
            rz = rzNew
        }
        return x
    }

    /// LDL^T factorisation of a symmetric positive definite matrix with bandwidth 2 (no pivoting), stored in the layout of
    /// `band`. Returns the unit lower factor's entries (below the diagonal) and the diagonal.
    static func bandedFactor(_ a: [Double], n: Int) -> (l: [Double], d: [Double]) {
        var l = [Double](repeating: 0, count: 5 * n)
        var d = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - 2)
            for j in lo..<i {
                var s = a[5 * i + (j - i + 2)]
                for k in lo..<j {
                    s -= l[5 * i + (k - i + 2)] * l[5 * j + (k - j + 2)] * d[k]
                }
                l[5 * i + (j - i + 2)] = s / d[j]
            }
            var s = a[5 * i + 2]
            for k in lo..<i {
                let lik = l[5 * i + (k - i + 2)]
                s -= lik * lik * d[k]
            }
            d[i] = s
        }
        return (l, d)
    }

    /// Solves the system factored by `bandedFactor` for the right-hand side `b`.
    static func bandedSolve(_ f: (l: [Double], d: [Double]), _ b: [Double], n: Int) -> [Double] {
        let l = f.l, d = f.d
        var y = b
        for i in 0..<n {
            for j in max(0, i - 2)..<i {
                y[i] -= l[5 * i + (j - i + 2)] * y[j]
            }
        }
        for i in 0..<n { y[i] /= d[i] }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in (i + 1)..<min(n, i + 3) {
                y[i] -= l[5 * k + (i - k + 2)] * y[k]
            }
        }
        return y
    }

    /// The same for a closed loop of waypoints. Samples the route, smooths its altitudes, then maps the result back onto the
    /// waypoints the way `ProfileRepair` does: each waypoint's segment is lifted by the worst shortfall among the samples it
    /// flies, and the waypoints are smoothed at the gradient. Only `alt` changes, and it is only ever raised.
    public static func smooth(waypoints: [Waypoint], settings: Settings = Settings()) -> [Waypoint] {
        let original = waypoints
        let n = original.count
        guard n >= 4 else { return original }
        let route = Route(file: RouteFile(name: "Smooth", closed: true, waypoints: original))
        let samples = route.samples
        let m = samples.count
        guard m >= 3 else { return original }

        let target = smooth(altitudes: samples.map(\.altitude), speeds: samples.map(\.speed), spacing: route.spacing,
                            settings: settings)

        var at = [Int](repeating: 0, count: n)
        var from = 0
        for k in 0..<n {
            from = ProfileRepair.nearestSample(to: original[k], from: from, samples: samples)
            at[k] = from
        }

        var wps = original
        for _ in 0..<ProfileRepair.maxSweeps {
            let flown = Route(file: RouteFile(name: "Smooth", closed: true, waypoints: wps)).samples
            guard flown.count == m else { break }
            var lift = [Double](repeating: 0, count: n)
            for k in 0..<n {
                let a = at[k], span = (at[(k + 1) % n] - a + m) % m
                for t in 0...span {
                    let j = (a + t) % m
                    lift[k] = max(lift[k], target[j] - flown[j].altitude)
                }
            }
            guard lift.contains(where: { $0 > ProfileRepair.settled }) else { break }
            for k in 0..<n where lift[k] > ProfileRepair.settled {
                wps[k].alt += lift[k]
                wps[(k + 1) % n].alt += lift[k]
            }
            ProfileRepair.smoothWaypoints(&wps, gradient: settings.gradient)
        }
        return wps
    }

    /// `plan` with its waypoint altitudes smoothed. Only `assembly.waypoints[k].alt` changes.
    public static func smooth(_ plan: RoutePlan, settings: Settings = Settings()) -> RoutePlan {
        var out = plan
        out.assembly.waypoints = smooth(waypoints: plan.assembly.waypoints, settings: settings)
        return out
    }
}
