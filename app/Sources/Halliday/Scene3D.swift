// 3D places (ROADMAP W12 D.4): real geometry to stand in, drawn with depth before the scene pass
// and shown where it is nearer than the environment (Renderer: the geometry pass; Shaders.swift:
// mesh_vs / mesh_fs and the "Geometry" step of scene_fs). Panels always draw over it: they are
// in front of whatever room the user is in.
//
// A scene is a list of parts (triangles with one material each) in Halliday's space: meters, y up,
// the floor at y = 0, the user near the origin. It comes from a file through ModelIO (.usdz, .usdc,
// .usda, .obj: what Reality Composer, Blender and most tools export), or is built in code.

import Metal
import MetalKit
import ModelIO
import simd

/// One vertex as the geometry pass reads it (must match `PlaceVertex` in Shaders.swift).
struct PlaceVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
}

/// Built once and then only read (it crosses from the loading thread to the main one).
final class Scene3D: @unchecked Sendable {
    struct Part {
        let vertices: MTLBuffer
        let vertexOffset: Int
        let indices: MTLBuffer
        let indexOffset: Int
        let indexCount: Int
        let indexType: MTLIndexType
        /// World from the part's own coordinates.
        let transform: simd_float4x4
        let baseColor: SIMD4<Float>
        let emission: SIMD3<Float>
        let texture: MTLTexture?
    }

    let name: String
    let parts: [Part]
    /// Triangles in all, for the log.
    let triangles: Int

    init(name: String, parts: [Part], triangles: Int) {
        self.name = name
        self.parts = parts
        self.triangles = triangles
    }

    /// The layout of `PlaceVertex` for ModelIO: position, normal, uv, packed, 32 bytes.
    static func makeVertexDescriptor() -> MDLVertexDescriptor {
        let d = MDLVertexDescriptor()
        d.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        d.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        d.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        d.layouts[0] = MDLVertexBufferLayout(stride: 32)
        return d
    }

    enum LoadError: Error, CustomStringConvertible {
        case empty
        var description: String { "it has no geometry Halliday can draw" }
    }

    /// Reads a scene file. Off the main thread is fine. The scene is scaled to meters if it looks
    /// like centimeters, and set on the floor (its lowest point at y = 0).
    static func load(_ url: URL, device: MTLDevice) throws -> Scene3D {
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
        asset.loadTextures()
        let box = asset.boundingBox
        let extent = box.maxBounds - box.minBounds
        // A room hundreds of units across was made in centimeters.
        let scale: Float = max(extent.x, max(extent.y, extent.z)) > 200 ? 0.01 : 1
        // On the floor; centered under the user only if the origin is outside it.
        var offset = SIMD3<Float>(0, -box.minBounds.y * scale, 0)
        let center = (box.minBounds + box.maxBounds) / 2 * scale
        if 0 < box.minBounds.x || 0 > box.maxBounds.x || 0 < box.minBounds.z || 0 > box.maxBounds.z {
            offset.x = -center.x
            offset.z = -center.z
        }
        let placeIt = simd_float4x4(translation: offset) * simd_float4x4(diagonal: SIMD4(scale, scale, scale, 1))
        let loader = MTKTextureLoader(device: device)
        var parts: [Part] = []
        var triangles = 0
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
            mesh.vertexDescriptor = makeVertexDescriptor()
            guard let mtk = try? MTKMesh(mesh: mesh, device: device), let vb = mtk.vertexBuffers.first else { continue }
            let world = placeIt * MDLTransform.globalTransform(with: mesh, atTime: 0)
            for (submesh, source) in zip(mtk.submeshes, (mesh.submeshes as? [MDLSubmesh]) ?? []) where submesh.primitiveType == .triangle {
                let material = source.material
                var color = SIMD4<Float>(0.7, 0.7, 0.72, 1)
                var texture: MTLTexture?
                if let p = material?.property(with: .baseColor) {
                    switch p.type {
                    case .float3: color = SIMD4(p.float3Value, 1)
                    case .float4: color = p.float4Value
                    case .color: if let c = p.color, let comps = c.components, c.numberOfComponents >= 3 {
                        color = SIMD4(Float(comps[0]), Float(comps[1]), Float(comps[2]), 1)
                    }
                    case .texture:
                        if let t = p.textureSamplerValue?.texture {
                            texture = try? loader.newTexture(texture: t, options: [.generateMipmaps: true, .SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
                        }
                    default: break
                    }
                }
                var emission = SIMD3<Float>(0, 0, 0)
                if let e = material?.property(with: .emission), e.type == .float3 { emission = e.float3Value }
                parts.append(Part(vertices: vb.buffer, vertexOffset: vb.offset, indices: submesh.indexBuffer.buffer, indexOffset: submesh.indexBuffer.offset,
                                  indexCount: submesh.indexCount, indexType: submesh.indexType, transform: world, baseColor: color,
                                  emission: emission, texture: texture))
                triangles += submesh.indexCount / 3
            }
        }
        guard !parts.isEmpty else { throw LoadError.empty }
        return Scene3D(name: url.deletingPathExtension().lastPathComponent, parts: parts, triangles: triangles)
    }
}

extension simd_float4x4 {
    init(diagonal d: SIMD4<Float>) {
        self = matrix_identity_float4x4
        columns.0.x = d.x; columns.1.y = d.y; columns.2.z = d.z; columns.3.w = d.w
    }
}
