import Foundation

/// World layout shared by the simulation and the renderer.
/// Units are metres. x right, y up, z towards the player (the screen is at -z).
public enum Arena {
    /// The plane where a block sits exactly on its beat.
    public static let hitPlaneZ: Double = -1.3
    /// Blocks become visible this far down the track.
    public static let spawnZ: Double = -48
    /// A block that gets this close without being cut is a miss.
    public static let missZ: Double = 0.35
    /// Blocks are removed from the scene after this z.
    public static let despawnZ: Double = 2.0

    public static let columnSpacing: Double = 0.55
    public static let rowSpacing: Double = 0.5
    public static let baseRowY: Double = 0.6

    /// Visual size of a block.
    public static let blockSize: Double = 0.45
    /// Generous hit box (half extents) so cuts tracked with low-rate sensors still connect.
    public static let hitHalfExtents = Vec3(0.3, 0.3, 0.45)
    public static let bombRadius: Double = 0.24

    /// Virtual shoulder pivots. The saber is a long lever from here:
    /// pointing at a block moves the blade through it.
    public static func pivot(for hand: Hand) -> Vec3 {
        hand == .left ? Vec3(-0.22, 1.15, 0.35) : Vec3(0.22, 1.15, 0.35)
    }
    /// Distance from the pivot to the hilt (the "arm").
    public static let hiltDistance: Double = 1.0
    /// Visible blade length beyond the hilt.
    public static let bladeLength: Double = 1.15

    public static func gridPosition(column: Int, row: Int) -> (x: Double, y: Double) {
        ((Double(column) - 1.5) * columnSpacing, baseRowY + Double(row) * rowSpacing)
    }

    /// Camera placement for the flat-screen view.
    public static let cameraPosition = Vec3(0, 1.55, 1.6)
    public static let cameraTarget = Vec3(0, 1.0, -3)
}

/// Where a block is at a given song time (includes the "jump in" animation).
public struct NoteMotion: Sendable {
    public var speed: Double
    /// Time before the beat at which the block finishes jumping into its lane.
    public var jumpDuration: Double = 0.7

    public init(speed: Double) { self.speed = speed }

    public func z(beatTime: Double, now: Double) -> Double {
        Arena.hitPlaneZ - (beatTime - now) * speed
    }

    /// Full animated position for rendering and collision.
    public func position(column: Int, row: Int, beatTime: Double, now: Double) -> Vec3 {
        let g = Arena.gridPosition(column: column, row: row)
        let z = self.z(beatTime: beatTime, now: now)
        let timeToHit = beatTime - now
        // Rise from the floor into the target row while far away.
        let riseStart = jumpDuration + 0.6
        var y = g.y
        if timeToHit > jumpDuration {
            let p = clamp((riseStart - timeToHit) / 0.6, 0, 1)
            let eased = 1 - pow(1 - p, 3)
            y = 0.25 + (g.y - 0.25) * eased
        }
        return Vec3(g.x, y, z)
    }

    /// Extra spin applied while the block is jumping in (radians around z); 0 once settled.
    public func spin(beatTime: Double, now: Double) -> Double {
        let timeToHit = beatTime - now
        guard timeToHit > jumpDuration * 0.6 else { return 0 }
        let p = clamp((timeToHit - jumpDuration * 0.6) / 0.6, 0, 1)
        return p * p * .pi
    }

    /// Scale while spawning (fade/grow in when far away).
    public func appearScale(beatTime: Double, now: Double) -> Double {
        let z = self.z(beatTime: beatTime, now: now)
        let p = clamp((z - Arena.spawnZ) / 6, 0, 1)
        return 0.3 + 0.7 * p
    }
}

/// Saber segment for a given direction.
public struct SaberGeometry: Sendable {
    public var pivot: Vec3
    public var direction: Vec3
    public init(pivot: Vec3, direction: Vec3) { self.pivot = pivot; self.direction = direction.normalized }
    public var hilt: Vec3 { pivot + direction * Arena.hiltDistance }
    public var tip: Vec3 { pivot + direction * (Arena.hiltDistance + Arena.bladeLength) }
}

// MARK: - Intersection helpers

public enum Intersection {
    /// Segment vs axis-aligned box (slab method).
    public static func segmentHitsBox(_ a: Vec3, _ b: Vec3, center: Vec3, halfExtents h: Vec3) -> Bool {
        let d = b - a
        var tmin = 0.0, tmax = 1.0
        let comps: [(Double, Double, Double, Double)] = [
            (a.x, d.x, center.x - h.x, center.x + h.x),
            (a.y, d.y, center.y - h.y, center.y + h.y),
            (a.z, d.z, center.z - h.z, center.z + h.z),
        ]
        for (o, dir, lo, hi) in comps {
            if abs(dir) < 1e-12 {
                if o < lo || o > hi { return false }
            } else {
                var t1 = (lo - o) / dir
                var t2 = (hi - o) / dir
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1)
                tmax = min(tmax, t2)
                if tmin > tmax { return false }
            }
        }
        return true
    }

    public static func distancePointSegment(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
        let ab = b - a
        let t = clamp((p - a).dot(ab) / max(ab.lengthSquared, 1e-12), 0, 1)
        return (a + ab * t - p).length
    }
}
